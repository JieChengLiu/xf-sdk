plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.xfusion.sdk.demo"
    compileSdk = 36
    buildToolsVersion = "36.1.0"

    defaultConfig {
        applicationId = "com.xfusion.sdk.demo"
        // 和 SDK 声明的 minSdk 一致，顺便验证 SDK 在 Android 5.0 上可用
        minSdk = 21
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {
    // okhttp 随 SDK 的 pom 传递进来；org.json 用 Android 系统自带的
    implementation("com.xfusion.sdk:xf-sdk-core:0.2.0")
}
