package com.example.screensync

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val channelName = "com.tekchant.screensync/alert_loop"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			channelName
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"start" -> {
					AlertLoopService.start(
						this,
						call.argument<String>("title"),
						call.argument<String>("body")
					)
					result.success(null)
				}
				"stop" -> {
					AlertLoopService.stop(this)
					result.success(null)
				}
				else -> result.notImplemented()
			}
		}
	}
}
