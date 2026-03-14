allprojects {
    repositories {
        // Flutter国内镜像（Kotlin DSL语法：url = uri("xxx")）
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/maven/") }
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io/") }
        // 阿里云镜像（修正语法：去掉单引号，添加uri()和等号）
        maven { url = uri("https://maven.aliyun.com/repository/public/") }
        maven { url = uri("https://maven.aliyun.com/repository/google/") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin/") }
        // 原有仓库
        google()
        mavenCentral()
    }
}

// 构建目录重定向配置（保留不变）
val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 清理任务配置（保留不变）
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}