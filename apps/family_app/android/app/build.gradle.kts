plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.jinsunradio.family_app"
    compileSdk = 36 // firebase_messaging 等依賴要求 compileSdk ≥ 34
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications（推播前景顯示）需要 core library desugaring
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jinsunradio.family_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26) // Jitsi SDK 13 需要 minSdk ≥ 26（Android 8.0）
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Jitsi SDK 用 getIdentifier() 依名字查資源（如 dropbox_app_key），
            // 資源 shrink 看不到這種動態查詢會把它刪掉，導致啟動閃退。
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // core library desugaring 執行期程式庫（flutter_local_notifications 需要）
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// FCM 推播：只有放入 android/app/google-services.json 才套用 google-services；
// 尚未設定 Firebase 時自動跳過，App 仍可正常打包。放入設定檔後推播自動生效。
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
