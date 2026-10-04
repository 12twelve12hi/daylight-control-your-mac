package com.twelve.daylight.ink

import org.json.JSONObject

/**
 * The golden vectors (`solstream-v1.json`), read from the test APK's assets. Gradle packages the JVM-test copy
 * (`src/test/resources`) as the androidTest assets dir, so there is no fifth copy for scripts/check-golden.sh.
 */
object Golden {
    val manifest: JSONObject by lazy {
        val text = TestEnv.instrumentation.context.assets.open("solstream-v1.json").use { it.readBytes().toString(Charsets.UTF_8) }
        JSONObject(text)
    }

    fun case(name: String): JSONObject {
        val cases = manifest.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            if (c.getString("name") == name) return c
        }
        throw AssertionError("golden case $name missing")
    }

    fun bytes(name: String): ByteArray = hex(case(name).getString("hex"))

    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { i -> s.substring(2 * i, 2 * i + 2).toInt(16).toByte() }
}
