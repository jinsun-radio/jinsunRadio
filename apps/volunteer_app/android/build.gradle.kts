allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    // 部分第三方 plugin（如 flutter_ringtone_player）自身 compileSdk 仍停在 33，
    // 但其 androidx 依賴要求 ≥34，導致 release build 失敗。統一拉高所有子模組 compileSdk。
    // 註冊在最早的 subprojects block（evaluationDependsOn 之前），避免「already evaluated」。
    afterEvaluate {
        project.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
            ?.compileSdkVersion(36)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
