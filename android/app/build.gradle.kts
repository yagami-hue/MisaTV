plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kniephos.kniephos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.kniephos.kniephos"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        val keystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
        val storePasswordEnv = System.getenv("ANDROID_STORE_PASSWORD")
        val keyAliasEnv = System.getenv("ANDROID_KEY_ALIAS")
        val keyPasswordEnv = System.getenv("ANDROID_KEY_PASSWORD")
        if (!keystorePath.isNullOrBlank() &&
            !storePasswordEnv.isNullOrBlank() &&
            !keyAliasEnv.isNullOrBlank() &&
            !keyPasswordEnv.isNullOrBlank() &&
            file(keystorePath).exists()
        ) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = storePasswordEnv
                keyAlias = keyAliasEnv
                keyPassword = keyPasswordEnv
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // TVBox / CatVod Java spider host dependencies (required by SpiderHostPlugin / DexClassLoader)
    implementation("com.squareup.okhttp3:okhttp:3.12.13")
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("org.jsoup:jsoup:1.16.1")
    implementation("com.alibaba:fastjson:1.2.83")
}

flutter {
    source = "../.."
}
