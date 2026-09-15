package com.example.screensync

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class AlertFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"].orEmpty().trim().uppercase()
        val status = (data["new_status"] ?: data["order_status"])
            .orEmpty()
            .trim()
            .uppercase()
        val action = data["action_performed"].orEmpty().trim().uppercase()
        val stopAlert = data["stop_alert"].isTrueValue()

        if (stopAlert || shouldStop(type, status, action)) {
            AlertLoopService.stop(this)
            return
        }

        if (shouldStart(type, status)) {
            AlertLoopService.start(
                this,
                data["title"],
                data["body"]
            )
        }
    }

    private fun shouldStop(type: String, status: String, action: String): Boolean {
        if (type == "SERVICE_TASK_ACCEPTED" ||
            type == "SERVICE_REQUEST_ACCEPTED" ||
            type == "TASK_ACCEPTED" ||
            type == "ORDER_ACCEPTED" ||
            type == "FOOD_ORDER_ACCEPTED" ||
            type == "DELIVERY_ACCEPTED") {
            return true
        }

        if (type == "FOOD_ORDER_STATUS" &&
            status in setOf("ACCEPTED", "CANCELLED", "DELIVERED")) {
            return true
        }

        return action == "ACCEPTED" || action == "DELIVERED"
    }

    private fun shouldStart(type: String, status: String): Boolean {
        return type == "NEW_FOOD_ORDER" ||
            type == "NEW_SERVICE_REQUEST" ||
            type == "SERVICE_ORDER" ||
            type == "ESCALATION" ||
            (type == "FOOD_ORDER_STATUS" && status == "READY")
    }

    private fun String?.isTrueValue(): Boolean {
        return this?.trim()?.lowercase() == "true" || this == "1"
    }
}
