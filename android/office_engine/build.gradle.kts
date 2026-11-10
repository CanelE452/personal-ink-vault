plugins {
    id("com.android.library")
}

repositories {
    ivy {
        url = uri("https://storage.googleapis.com/r8-releases")
        patternLayout { artifact("/raw/[revision]/[module].[ext]") }
        metadataSources { artifact() }
        content { includeGroup("r8") }
    }
}

val repository = projectDir.parentFile.parentFile
val generatedOffice = File(repository, "build/office-engine/generated")
val prepareOfficeEngine by tasks.registering(Exec::class) {
    workingDir(repository)
    inputs.files(file("engine.lock.json"), file("prepare_engine.py"))
    outputs.file(File(generatedOffice, "prepared.json"))
    outputs.upToDateWhen {
        File(generatedOffice, "jniLibs/arm64-v8a/liblo-native-code.so").isFile &&
            File(generatedOffice, "assets/dist/cool.html").isFile &&
            File(generatedOffice, "java/org/libreoffice/androidlib/LOActivity.java").isFile
    }
    if (System.getProperty("os.name").startsWith("Windows")) {
        commandLine("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts/prepare-office-engine.ps1")
    } else {
        commandLine("bash", "scripts/prepare-office-engine.sh")
    }
}

extensions.configure<com.android.build.api.dsl.LibraryExtension> {
    namespace = "org.libreoffice.androidlib"
    compileSdk = 37
    ndkVersion = "29.0.14206865"
    defaultConfig {
        minSdk = 26
        ndk { abiFilters += "arm64-v8a" }
        buildConfigField("String", "GIT_COMMIT", "\"fd0b24ba59e043b2ed9087eb6324bbc6d281e93b-piv4\"")
        buildConfigField("boolean", "GOOGLE_PLAY_ENABLED", "false")
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++20", "-fvisibility=hidden")
                arguments += "-DANDROID_STL=c++_shared"
            }
        }
        consumerProguardFiles("consumer-rules.pro")
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("main") {
        java.srcDir(File(generatedOffice, "java"))
        res.srcDir(File(generatedOffice, "res"))
        assets.srcDir(File(generatedOffice, "assets"))
        jniLibs.srcDir(File(generatedOffice, "jniLibs"))
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    packaging.jniLibs.pickFirsts.add("lib/arm64-v8a/libc++_shared.so")
}

tasks.named("preBuild") { dependsOn(prepareOfficeEngine) }
tasks.matching { it.name.startsWith("configureCMake") }.configureEach { dependsOn(prepareOfficeEngine) }

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("com.google.android.material:material:1.14.0")
    implementation("androidx.constraintlayout:constraintlayout:2.2.1")
    compileOnly("r8:keepanno-annotations:9.3.16")
}
