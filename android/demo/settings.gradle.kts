pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // 本地联调：在 sdk/android/xf-sdk-core 下 mvn install 后优先用本地版本；没有就从下面的仓库下载
        mavenLocal()
        google()
        mavenCentral()
        // 发布的 SDK
        maven("https://raw.githubusercontent.com/JieChengLiu/xf-sdk/main/android/maven/")
    }
}

rootProject.name = "xf-sdk-demo"
include(":app")
