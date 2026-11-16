package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.os.Build;
import android.view.WindowInsets;
import android.view.WindowInsetsController;

/**
 * Keeps the navigation bar hidden in the document editors, as MainActivity does in the app itself: a swipe from the
 * screen edge shows it for a moment. Android 11 (API 30) and later only; older devices keep the bar.
 */
final class SystemBars {
    private SystemBars() {}

    static void hideNavigationBar(Activity activity) {
        if (Build.VERSION.SDK_INT < 30) return;
        WindowInsetsController controller = activity.getWindow().getInsetsController();
        if (controller == null) return;
        controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        controller.hide(WindowInsets.Type.navigationBars());
    }
}
