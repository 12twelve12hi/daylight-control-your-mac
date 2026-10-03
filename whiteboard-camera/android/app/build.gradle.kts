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
        versionCode = 1
        versionName = "0.1.0"
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
    testImplementation("junit:junit:4.13.2")
    // org.json on the unit-test classpath: the android.jar stub throws for every method.
    testImplementation("org.json:json:20250517")
}
