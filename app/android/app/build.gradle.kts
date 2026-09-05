plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.future.screenShare"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.future.screenShare"
        // 屏幕内音采集(AudioPlaybackCapture)需要 Android 10(Q)+,故 minSdk 固定为 29
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // flutter_webrtc 的 JNI 依赖类名反射,混淆会导致运行时静默崩溃;
            // 如需开启混淆,必须附加 -keep class com.cloudwebrtc.** / org.webrtc.** 规则
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // flutter_webrtc 以 implementation 依赖 webrtc SDK,不对外导出;
    // 本应用插件实现其音频处理接口时需要同样的类路径
    implementation("io.github.webrtc-sdk:android:125.6422.03")
}
