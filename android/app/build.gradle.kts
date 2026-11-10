import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val hasReleaseSigning = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
    .all { keystoreProperties.getProperty(it)?.isNotBlank() == true }

val buildInkVaultNative by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    inputs.files(fileTree(rootProject.file("../packages/ink_vault_native")) {
        include("Cargo.toml", "Cargo.lock", "src/**/*.rs")
    })
    inputs.files(rootProject.file("../scripts/build-native.ps1"), rootProject.file("../scripts/build-native.sh"))
    outputs.file(rootProject.file("../build/native/android/arm64-v8a/libink_vault_native.so"))
    if (System.getProperty("os.name").startsWith("Windows")) {
        commandLine("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts/build-native.ps1", "-Platform", "android")
    } else {
        commandLine("bash", "scripts/build-native.sh", "android", "release")
    }
}
tasks.named("preBuild") { dependsOn(buildInkVaultNative) }

val buildInkHwpNative by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    inputs.files(fileTree(rootProject.file("../packages/ink_hwp_native")) {
        include("Cargo.toml", "Cargo.lock", "src/**/*.rs")
    })
    inputs.files(rootProject.file("../scripts/build-hwp-native.ps1"), rootProject.file("../scripts/build-hwp-native.sh"))
    outputs.file(rootProject.file("../build/native/android/arm64-v8a/libink_hwp_native.so"))
    if (System.getProperty("os.name").startsWith("Windows")) {
        commandLine("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts/build-hwp-native.ps1", "-Platform", "android")
    } else {
        commandLine("bash", "scripts/build-hwp-native.sh", "android", "release")
    }
}
val prepareHwpFonts by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    inputs.files(rootProject.file("../packages/ink_hwp_native/fonts/manifest.json"), rootProject.file("../scripts/prepare-hwp-fonts.ps1"), rootProject.file("../scripts/prepare-hwp-fonts.sh"))
    outputs.files(rootProject.file("../build/native/fonts/NotoSansCJKkr-Regular.otf"), rootProject.file("../build/native/fonts/OFL.txt"))
    if (System.getProperty("os.name").startsWith("Windows")) {
        commandLine("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts/prepare-hwp-fonts.ps1")
    } else {
        commandLine("bash", "scripts/prepare-hwp-fonts.sh")
    }
}
val preparePortableExportFont by tasks.registering(Exec::class) {
    dependsOn(prepareHwpFonts)
    workingDir(rootProject.projectDir.parentFile)
    inputs.files(rootProject.file("../packages/ink_hwp_native/fonts/portable-export.json"), rootProject.file("../scripts/prepare-hwp-fonts.ps1"), rootProject.file("../scripts/prepare-hwp-fonts.sh"))
    outputs.file(rootProject.file("../build/native/fonts/NotoSansKR-Portable.ttf"))
    if (System.getProperty("os.name").startsWith("Windows")) {
        commandLine("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts/prepare-hwp-fonts.ps1", "-ManifestName", "portable-export.json")
    } else {
        commandLine("bash", "scripts/prepare-hwp-fonts.sh", "--manifest-name", "portable-export.json")
    }
}

tasks.named("preBuild") { dependsOn(buildInkHwpNative, prepareHwpFonts, preparePortableExportFont) }
tasks.matching { it.name.startsWith("compileFlutterBuild") }.configureEach { dependsOn(prepareHwpFonts, preparePortableExportFont) }

android {
    namespace = "io.github.canele452.personalinkvault"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion
    sourceSets.getByName("main").jniLibs.srcDir(rootProject.file("../build/native/android"))
    sourceSets.getByName("main").jniLibs.srcDir(rootProject.file("../build/office-engine/generated/app-jni"))

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.canele452.personalinkvault"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        if (project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
        }
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }
    buildTypes {
        release {
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    packaging {
        jniLibs.pickFirsts.add("lib/*/libc++_shared.so")
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
    implementation(project(":office_engine"))
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk7:2.2.10")
    implementation("com.google.android.material:material:1.14.0")
}

val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}
