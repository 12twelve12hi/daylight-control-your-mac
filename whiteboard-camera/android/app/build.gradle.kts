plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.twelve.daylight.ink"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.twelve.daylight.ink"
        minSdk = 30
        targetSdk = 33
        // CI passes -PdaylightVersionCode=$GITHUB_RUN_NUMBER so every build upgrades the previous sideload (handoff request).
        versionCode = (project.findProperty("daylightVersionCode") as String?)?.toIntOrNull()?.coerceAtLeast(1) ?: 1
        versionName = (project.findProperty("daylightVersionName") as String?) ?: "0.1.0"
    }

    // The committed debug keystore keeps every CI build signed with the same key, so `adb install -r`
    // upgrades an earlier sideload instead of failing on a signature mismatch (debug keys are not secrets).
    signingConfigs {
        getByName("debug") {
            storeFile = rootProject.file("keystore/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = false
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // research-android-ink section 8: no AppCompat, Material, Compose or lifecycle. Views only.
    implementation("androidx.graphics:graphics-core:1.0.4")      // CanvasFrontBufferedRenderer (wet ink)
    // The JVM artifact on purpose: the "okhttp" coordinate resolves to okhttp-android, whose AAR metadata demands
    // compileSdk 37 (beyond AGP 8.13.2's maximum of 36; CI run 37112754944). okhttp-jvm is the same WebSocket client.
    implementation("com.squareup.okhttp3:okhttp-jvm:5.5.0")      // WebSocket client (binary frames, pingInterval)
    testImplementation("junit:junit:4.13.2")
    // org.json on the unit-test classpath: the android.jar stub throws for every method.
    testImplementation("org.json:json:20250517")
}
