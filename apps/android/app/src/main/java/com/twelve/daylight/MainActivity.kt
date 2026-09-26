package com.twelve.daylight

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Html
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject

/**
 * Full-screen kiosk wrapper around the Twelve Daylight PWA.
 *
 * One WebView, pinned to the paired Mac's origin (`http://<mac-ip>:7712/?token=...`).
 * It never leaves the app: Back only navigates inside the page, links to other
 * origins are dropped, and the system bars stay hidden (swipe from an edge to
 * peek). Hold a finger on the top-left corner for three seconds to open the
 * setup screen and change the server address.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var prefs: SharedPreferences
    private lateinit var webView: WebView
    private lateinit var setupView: View
    private lateinit var urlInput: EditText
    private lateinit var errorText: TextView
    private lateinit var cancelButton: Button

    private val handler = Handler(Looper.getMainLooper())
    private val cornerHoldRunnable = Runnable { showSetup() }

    /** Origin (scheme, host, port) of the paired Mac. Navigation is restricted to it. */
    private var serverUri: Uri? = null

    /** True while the "cannot reach your Mac" page is up; history is cleared once it recovers. */
    private var showingRetryPage = false

    /** A page permission request parked while the RECORD_AUDIO runtime prompt is showing. */
    private var pendingPermissionRequest: PermissionRequest? = null

    private val micPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            val request = pendingPermissionRequest ?: return@registerForActivityResult
            pendingPermissionRequest = null
            if (granted) request.grant(request.resources) else request.deny()
        }

    private val savedServerUrl: String?
        get() = prefs.getString(KEY_SERVER_URL, null)?.takeIf { it.isNotBlank() }

    // ---------------------------------------------------------------- lifecycle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)

        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        webView = findViewById(R.id.web_view)
        setupView = findViewById(R.id.setup_root)
        urlInput = findViewById(R.id.url_input)
        errorText = findViewById(R.id.setup_error)
        cancelButton = findViewById(R.id.setup_cancel)

        configureWebView()
        wireSetup()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                handleBack()
            }
        })

        val url = savedServerUrl
        if (url == null) showSetup() else loadServer(url)
    }

    override fun onResume() {
        super.onResume()
        webView.onResume()
        enterImmersiveMode()
    }

    override fun onPause() {
        webView.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacks(cornerHoldRunnable)
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersiveMode()
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        trackCornerHold(ev)
        return super.dispatchTouchEvent(ev)
    }

    // ------------------------------------------------------------ full screen

    private fun enterImmersiveMode() {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
    }

    // ---------------------------------------------------------------- WebView

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            useWideViewPort = true
            loadWithOverviewMode = true
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            allowFileAccess = false
            allowContentAccess = false
            // Lets the PWA tell the wrapper apart from Chrome if it ever wants to.
            userAgentString = "$userAgentString TwelveDaylight/${BuildConfig.VERSION_NAME}"
        }
        // The DC-1 is a paper-like display and the PWA is designed light; never auto-darken.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(webView.settings, false)
        }
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        webView.overScrollMode = View.OVER_SCROLL_NEVER
        webView.webChromeClient = KioskChromeClient()
        webView.webViewClient = KioskWebViewClient()
        // chrome://inspect on a connected computer, debug builds only.
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
    }

    private fun loadServer(url: String) {
        serverUri = Uri.parse(url)
        webView.loadUrl(url)
    }

    /** True when [uri] has the same scheme, host and port as the paired server. */
    private fun isServerOrigin(uri: Uri?): Boolean {
        val server = serverUri ?: return false
        if (uri == null) return false
        return uri.scheme.equals(server.scheme, ignoreCase = true) &&
            uri.host.equals(server.host, ignoreCase = true) &&
            portOf(uri) == portOf(server)
    }

    private fun portOf(uri: Uri): Int = when {
        uri.port != -1 -> uri.port
        uri.scheme.equals("https", ignoreCase = true) -> 443
        else -> 80
    }

    private fun hasMicPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Minimal in-app "offline" page. Shown instead of Chromium's default error page
     * (which prints the URL, token included); retries the server every five seconds.
     */
    private fun showRetryPage(view: WebView, reason: String?) {
        val target = serverUri?.toString() ?: return
        val href = Html.escapeHtml(target)
        val jsTarget = JSONObject.quote(target)
        val detail = if (reason.isNullOrBlank()) "" else "<p><small>${Html.escapeHtml(reason)}</small></p>"
        val html = """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
                     font-family: sans-serif; background: #fff; color: #111; text-align: center; }
              p { margin: 0.5em 0; }
              a { color: #111; font-size: 1.25em; }
              small { color: #666; }
            </style></head>
            <body><div>
              <p>Cannot reach your Mac.</p>
              <p><a href="$href">Try again</a></p>
              <p><small>Retrying automatically. Hold the top-left corner for 3 seconds to change the address.</small></p>
              $detail
            </div>
            <script>setTimeout(function () { location.replace($jsTarget); }, 5000);</script>
            </body></html>
        """.trimIndent()
        showingRetryPage = true
        view.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }

    private inner class KioskWebViewClient : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            // Stay inside the kiosk: only the paired server's origin may be navigated to.
            return !isServerOrigin(request.url)
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            // Main frame only, and only for the paired server: an old load aborted by a
            // fresh loadServer() must not replace the new page with the retry page.
            if (request.isForMainFrame && isServerOrigin(request.url)) {
                showRetryPage(view, error.description?.toString())
            }
        }

        override fun onPageFinished(view: WebView, url: String) {
            if (showingRetryPage && isServerOrigin(Uri.parse(url))) {
                // Back in the app: drop the retry pages so Back does not walk through them.
                showingRetryPage = false
                view.clearHistory()
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // The renderer died (crash or OOM). Rebuild the activity, which rebuilds the WebView.
            recreate()
            return true
        }
    }

    private inner class KioskChromeClient : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) {
            val wanted = request.resources
            val audioOnly = wanted.isNotEmpty() &&
                wanted.all { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
            if (!audioOnly || !isServerOrigin(request.origin)) {
                request.deny()
                return
            }
            when {
                hasMicPermission() -> request.grant(wanted)
                pendingPermissionRequest == null -> {
                    pendingPermissionRequest = request
                    micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                }
                else -> request.deny()
            }
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            if (pendingPermissionRequest === request) pendingPermissionRequest = null
        }
    }

    // ------------------------------------------------------------------ setup

    private fun wireSetup() {
        findViewById<Button>(R.id.setup_connect).setOnClickListener { submitSetup() }
        cancelButton.setOnClickListener { hideSetup() }
        urlInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_GO || actionId == EditorInfo.IME_ACTION_DONE) {
                submitSetup()
                true
            } else {
                false
            }
        }
    }

    private fun showSetup() {
        handler.removeCallbacks(cornerHoldRunnable)
        val current = savedServerUrl
        urlInput.setText(current ?: "")
        urlInput.setSelection(urlInput.text.length)
        errorText.isVisible = false
        cancelButton.isVisible = current != null
        setupView.isVisible = true
        urlInput.requestFocus()
    }

    private fun hideSetup() {
        WindowInsetsControllerCompat(window, urlInput).hide(WindowInsetsCompat.Type.ime())
        setupView.isVisible = false
        enterImmersiveMode()
    }

    private fun submitSetup() {
        val uri = parseServerUrl(urlInput.text.toString())
        if (uri == null) {
            errorText.isVisible = true
            return
        }
        prefs.edit().putString(KEY_SERVER_URL, uri.toString()).apply()
        hideSetup()
        loadServer(uri.toString())
    }

    /** Accepts `http(s)://host[:port]/...`; a bare `host:port/...` gets `http://` prepended. */
    private fun parseServerUrl(raw: String): Uri? {
        var text = raw.trim()
        if (text.isEmpty()) return null
        if (!text.contains("://")) text = "http://$text"
        val uri = Uri.parse(text)
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        if (uri.host.isNullOrEmpty()) return null
        return uri
    }

    private fun handleBack() {
        when {
            setupView.isVisible -> if (savedServerUrl != null) hideSetup()
            webView.canGoBack() -> webView.goBack()
            // Otherwise do nothing: the kiosk never backs out of itself.
        }
    }

    // ----------------------------------------------------------- corner hold

    /**
     * Invisible hotspot: a finger held still in the top-left corner for [CORNER_HOLD_MS]
     * opens the setup screen. Touches are observed here and passed on untouched, so the
     * page still receives them. Stylus input is ignored so writing never triggers it.
     */
    private fun trackCornerHold(ev: MotionEvent) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val finger = ev.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER
                if (finger && !setupView.isVisible && isInCorner(ev)) {
                    handler.postDelayed(cornerHoldRunnable, CORNER_HOLD_MS)
                }
            }
            MotionEvent.ACTION_MOVE -> if (!isInCorner(ev)) handler.removeCallbacks(cornerHoldRunnable)
            MotionEvent.ACTION_POINTER_DOWN,
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> handler.removeCallbacks(cornerHoldRunnable)
        }
    }

    private fun isInCorner(ev: MotionEvent): Boolean {
        val size = CORNER_SIZE_DP * resources.displayMetrics.density
        return ev.x in 0f..size && ev.y in 0f..size
    }

    companion object {
        private const val PREFS_NAME = "twelve"
        private const val KEY_SERVER_URL = "server_url"
        private const val CORNER_HOLD_MS = 3000L
        private const val CORNER_SIZE_DP = 96f
    }
}
