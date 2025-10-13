# ProGuard / R8 rules for Flutter app
# Keep Flutter classes
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep Kotlin (prevent some reflection issues)
-keep class kotlin.Metadata { *; }

# (Optional) If using Gson or other reflection-based serializers, add keep rules here.
# -keep class com.yourpackage.model.** { *; }

# Add any BLE library specific rules if minification causes issues.
# Example (uncomment if needed):
# -keep class com.signify.hue.** { *; }

# End of file
