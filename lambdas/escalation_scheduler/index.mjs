'use strict';

import mysql from 'mysql';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

import admin from 'firebase-admin';
import { getMessaging } from 'firebase-admin/messaging';


const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let firebaseInitialized = false;


/* ============================================================
   FIREBASE INITIALIZATION
   ============================================================ */

function initializeFirebase() {

    if (firebaseInitialized) {
        return true;
    }

    const keyPath =
        path.join(__dirname, 'firebase-key.json');

    if (!fs.existsSync(keyPath)) {

        console.warn(
            'Firebase key not found. Notifications disabled.'
        );

        return false;
    }

    try {

        const serviceAccount =
            JSON.parse(
                fs.readFileSync(
                    keyPath,
                    'utf8'
                )
            );

        if (!admin.apps.length) {

            admin.initializeApp({
                credential:
                    admin.credential.cert(serviceAccount)
            });
        }

        firebaseInitialized = true;

        console.log(
            'Firebase initialized successfully'
        );

        return true;

    } catch (error) {

        console.error(
            'Firebase initialization failed:',
            error.message
        );

        firebaseInitialized = false;

        return false;
    }
}


/* ============================================================
   MYSQL QUERY HELPER
   ============================================================ */

function query(
    connection,
    sql,
    params = []
) {

    return new Promise(
        (resolve, reject) => {

            connection.query(
                sql,
                params,
                (error, results) => {

                    if (error) {
                        reject(error);
                        return;
                    }

                    resolve(results);
                }
            );
        }
    );
}


/* ============================================================
   FIND RESULT SET FROM MYSQL PROCEDURE
   ============================================================ */

function findResultSet(
    results,
    requiredKey
) {

    if (!Array.isArray(results)) {
        return [];
    }

    for (const result of results) {

        if (
            !Array.isArray(result) ||
            result.length === 0
        ) {
            continue;
        }

        if (
            Object.prototype.hasOwnProperty.call(
                result[0],
                requiredKey
            )
        ) {

            return result;
        }
    }

    return [];
}


/* ============================================================
   EXTRACT ESCALATION COUNT FROM PROCEDURE MESSAGE
   ============================================================ */

/*
   Expected procedure messages:

   Service:
   "Escalation check completed. Checked: 10, Escalated: 2, Skipped: 8"

   Food:
   "Food escalation check completed. Checked: 5, Escalated: 1, Skipped: 4"
*/

function extractEscalationsCreated(result) {

    if (!result) {
        return 0;
    }

    if (
        String(
            result.status || ''
        ).toUpperCase() === 'F'
    ) {
        return 0;
    }

    const message =
        String(
            result.message || ''
        );

    const match =
        message.match(
            /Escalated:\s*(\d+)/i
        );

    if (!match) {
        return 0;
    }

    return Number(match[1]) || 0;
}


/* ============================================================
   START SCHEDULER LOG
   ============================================================ */

async function startSchedulerLog(
    connection,
    stage
) {

    const input =
        JSON.stringify({
            stage
        });

    const results =
        await query(
            connection,
            `
            CALL ScreenSync.start_escalation_scheduler_log(
                ${connection.escape(input)},
                @p_flag,
                @p_message
            )
            `
        );

    const logRows =
        findResultSet(
            results,
            'scheduler_log_id'
        );

    if (
        !logRows.length ||
        !logRows[0].scheduler_log_id
    ) {

        throw new Error(
            'Unable to create escalation scheduler log'
        );
    }

    const schedulerLogId =
        Number(
            logRows[0].scheduler_log_id
        );

    console.log(
        'Scheduler log created:',
        schedulerLogId
    );

    return schedulerLogId;
}


/* ============================================================
   RUN SERVICE ESCALATION
   ============================================================ */

async function runServiceEscalationProcedure(
    connection
) {

    const results =
        await query(
            connection,
            `
            CALL ScreenSync.check_and_escalate_unified(
                @p_flag,
                @p_message
            )
            `
        );

    const statusRows =
        findResultSet(
            results,
            'status'
        );

    const result =
        statusRows.length
            ? statusRows[0]
            : {
                status: 'S',
                message:
                    'Service escalation procedure executed'
            };

    console.log(
        'check_and_escalate_unified:',
        JSON.stringify(result)
    );

    if (
        String(
            result.status || ''
        ).toUpperCase() === 'F'
    ) {

        throw new Error(
            result.message ||
            'Service escalation procedure failed'
        );
    }

    return result;
}


/* ============================================================
   RUN FOOD ESCALATION
   ============================================================ */

async function runFoodEscalationProcedure(
    connection
) {

    const results =
        await query(
            connection,
            `
            CALL ScreenSync.check_and_escalate_food(
                @p_flag,
                @p_message
            )
            `
        );

    const statusRows =
        findResultSet(
            results,
            'status'
        );

    const result =
        statusRows.length
            ? statusRows[0]
            : {
                status: 'S',
                message:
                    'Food escalation procedure executed'
            };

    console.log(
        'check_and_escalate_food:',
        JSON.stringify(result)
    );

    if (
        String(
            result.status || ''
        ).toUpperCase() === 'F'
    ) {

        throw new Error(
            result.message ||
            'Food escalation procedure failed'
        );
    }

    return result;
}


/* ============================================================
   GET PENDING ESCALATION NOTIFICATIONS
   ============================================================ */

async function getPendingNotifications(
    connection
) {

    const results =
        await query(
            connection,
            `
            CALL ScreenSync.get_pending_escalation_notifications(
                @p_flag,
                @p_message
            )
            `
        );

    const rows =
        findResultSet(
            results,
            'notification_log_id'
        );

    console.log(
        'Pending escalation notifications:',
        rows.length
    );

    return rows;
}


/* ============================================================
   GET USER FCM TOKENS
   ============================================================ */

async function getUserFcmTokens(
    connection,
    userId
) {

    const input =
        JSON.stringify({
            user_id:
                Number(userId)
        });

    const results =
        await query(
            connection,
            `
            CALL ScreenSync.get_user_fcm_tokens_mobile(
                ${connection.escape(input)},
                @p_flag,
                @p_message
            )
            `
        );

    const rows =
        findResultSet(
            results,
            'fcm_token'
        );

    const tokens = [
        ...new Set(

            rows
                .map(
                    row =>
                        String(
                            row.fcm_token || ''
                        ).trim()
                )
                .filter(Boolean)
        )
    ];

    return tokens;
}


/* ============================================================
   MARK NOTIFICATION SENT
   ============================================================ */

async function markNotificationSent(
    connection,
    notificationLogId,
    successCount
) {

    const input =
        JSON.stringify({

            notification_log_id:
                Number(
                    notificationLogId
                ),

            success_count:
                Number(
                    successCount
                )
        });

    await query(
        connection,
        `
        CALL ScreenSync.mark_escalation_notification_sent(
            ${connection.escape(input)},
            @p_flag,
            @p_message
        )
        `
    );
}


/* ============================================================
   MARK NOTIFICATION FAILED
   ============================================================ */

async function markNotificationFailed(
    connection,
    notificationLogId,
    errorMessage
) {

    const input =
        JSON.stringify({

            notification_log_id:
                Number(
                    notificationLogId
                ),

            error_message:
                String(
                    errorMessage ||
                    'FCM notification failed'
                ).slice(0, 500)
        });

    await query(
        connection,
        `
        CALL ScreenSync.mark_escalation_notification_failed(
            ${connection.escape(input)},
            @p_flag,
            @p_message
        )
        `
    );
}


/* ============================================================
   COMPLETE SCHEDULER LOG
   ============================================================ */

async function completeSchedulerLog(
    connection,
    schedulerLogId,
    status,
    message,
    escalationsCreated,
    notificationsPending,
    notificationsSent,
    notificationsFailed
) {

    const input =
        JSON.stringify({

            scheduler_log_id:
                Number(
                    schedulerLogId
                ),

            status,

            message:
                String(
                    message || ''
                ).slice(0, 500),

            escalations_created:
                Number(
                    escalationsCreated || 0
                ),

            notifications_pending:
                Number(
                    notificationsPending || 0
                ),

            notifications_sent:
                Number(
                    notificationsSent || 0
                ),

            notifications_failed:
                Number(
                    notificationsFailed || 0
                )
        });

    await query(
        connection,
        `
        CALL ScreenSync.complete_escalation_scheduler_log(
            ${connection.escape(input)},
            @p_flag,
            @p_message
        )
        `
    );
}


/* ============================================================
   BUILD NOTIFICATION MESSAGE
   ============================================================ */

function buildNotificationMessage(
    row
) {

    const escalationType =
        String(
            row.escalation_type || ''
        ).toUpperCase();


    if (
        escalationType === 'FOOD'
    ) {

        const orderNumber =
            row.food_order_number ||
            row.food_summary_id ||
            'Food order';

        return (
            `Food order ${orderNumber} has been escalated to you`
        );
    }


    const serviceRequestId =
        row.service_request_id ||
        '';

    return (
        `Service request ${serviceRequestId} has been escalated to you`
    );
}


/* ============================================================
   SEND ONE ESCALATION NOTIFICATION
   ============================================================ */

async function sendEscalationNotification(
    connection,
    row
) {

    const notificationLogId =
        Number(
            row.notification_log_id
        );

    const userId =
        Number(
            row.user_id
        );


    /* ========================================================
       GET FCM TOKENS
       ======================================================== */

    const tokens =
        await getUserFcmTokens(
            connection,
            userId
        );


    if (
        tokens.length === 0
    ) {

        await markNotificationFailed(
            connection,
            notificationLogId,
            'No active FCM token found for user'
        );

        return {
            sent: 0,
            failed: 1
        };
    }


    /* ========================================================
       FIREBASE CHECK
       ======================================================== */

    if (
        !firebaseInitialized
    ) {

        await markNotificationFailed(
            connection,
            notificationLogId,
            'Firebase is not initialized'
        );

        return {
            sent: 0,
            failed: 1
        };
    }


    const messaging =
        getMessaging();


    /* ========================================================
       COMMON VALUES
       ======================================================== */

    const notificationType =
        String(
            row.notification_type || ''
        );

    const message =
        buildNotificationMessage(
            row
        );


    /* ========================================================
       FCM PAYLOAD

       No WebSocket.
       websocket_sent remains 0 in DB.
       ======================================================== */

    const payload = {

        tokens:
            tokens.slice(
                0,
                500
            ),

        data: {

            type:
                'ESCALATION',

            title:
                'Escalation',

            body:
                message,

            event_id:
                String(
                    row.event_id || ''
                ),

            escalation_log_id:
                String(
                    row.escalation_log_id || ''
                ),

            notification_log_id:
                String(
                    row.notification_log_id || ''
                ),

            enterprise_id:
                String(
                    row.enterprise_id || ''
                ),

            department_id:
                String(
                    row.department_id || ''
                ),

            department_name:
                String(
                    row.department_name || ''
                ),

            escalation_type:
                String(
                    row.escalation_type || ''
                ),

            escalation_level:
                String(
                    row.escalation_level || ''
                ),

            from_user_id:
                String(
                    row.from_user_id || ''
                ),

            from_user_name:
                String(
                    row.from_user_name || ''
                ),

            to_user_id:
                String(
                    row.to_user_id || ''
                ),

            to_user_name:
                String(
                    row.to_user_name || ''
                ),

            from_role_name:
                String(
                    row.from_role_name || ''
                ),

            to_role_name:
                String(
                    row.to_role_name || ''
                ),

            reason:
                String(
                    row.reason || ''
                ),

            /* SERVICE */

            service_request_id:
                String(
                    row.service_request_id || ''
                ),

            /* FOOD */

            food_summary_id:
                String(
                    row.food_summary_id || ''
                ),

            food_order_number:
                String(
                    row.food_order_number || ''
                ),

            food_order_status:
                String(
                    row.food_order_status || ''
                ),

            food_guest_id:
                String(
                    row.food_guest_id || ''
                ),

            food_device_id:
                String(
                    row.food_device_id || ''
                ),

            message,

            timestamp:
                new Date().toISOString()
        },

        android: {

            priority:
                'high'
        },

        apns: {

            payload: {

                aps: {

                    sound:
                        'default',

                    badge:
                        1
                }
            }
        }
    };


    try {

        const result =
            await messaging.sendEachForMulticast(
                payload
            );


        console.log(
            `Escalation notification ${notificationLogId}:`,
            `type=${notificationType},`,
            `success=${result.successCount},`,
            `failed=${result.failureCount}`
        );


        /* ====================================================
           SUCCESS
           ==================================================== */

        if (
            result.successCount > 0
        ) {

            await markNotificationSent(
                connection,
                notificationLogId,
                result.successCount
            );

            return {

                sent: 1,

                failed: 0
            };
        }


        /* ====================================================
           ALL FCM SENDS FAILED
           ==================================================== */

        const failureMessage =
            result.responses
                ?.filter(
                    response =>
                        !response.success
                )
                ?.map(
                    response =>
                        response.error?.message
                )
                ?.filter(Boolean)
                ?.join('; ')
            ||
            'All FCM sends failed';


        await markNotificationFailed(
            connection,
            notificationLogId,
            failureMessage
        );


        return {

            sent: 0,

            failed: 1
        };


    } catch (error) {

        console.error(
            `FCM error for notification ${notificationLogId}:`,
            error.message
        );


        await markNotificationFailed(
            connection,
            notificationLogId,
            error.message
        );


        return {

            sent: 0,

            failed: 1
        };
    }
}


/* ============================================================
   LAMBDA HANDLER
   ============================================================ */

export const handler = (
    event,
    context,
    callback
) => {

    context.callbackWaitsForEmptyEventLoop =
        false;


    /*
     * EventBridge does not need enterprise_id.
     *
     * Both escalation procedures process
     * all active enterprises.
     */

    const stage =
        'dev';


    const configFile =
        '/opt/nodejs/node_modules/dbConfig_dev.json';


    let dbconfig;


    /* ============================================================
       READ DATABASE CONFIG
       ============================================================ */

    try {

        dbconfig =
            JSON.parse(
                fs.readFileSync(
                    configFile,
                    'utf8'
                )
            );

    } catch (error) {

        callback(
            `Error reading DB config: ${error.message}`
        );

        return;
    }


    /* ============================================================
       MYSQL POOL
       ============================================================ */

    const pool =
        mysql.createPool({

            host:
                dbconfig.dbhost,

            user:
                dbconfig.dbuser,

            password:
                dbconfig.dbpassword,

            database:
                dbconfig.dbname,

            connectionLimit:
                2
        });


    pool.getConnection(
        async (
            error,
            connection
        ) => {

            if (error) {

                callback(
                    error
                );

                return;
            }


            let schedulerLogId =
                null;


            let escalationsCreated =
                0;


            let notificationsPending =
                0;


            let notificationsSent =
                0;


            let notificationsFailed =
                0;


            try {

                console.log(
                    'Connected to DB:',
                    dbconfig.dbname
                );


                /* ====================================================
                   1. CREATE SCHEDULER LOG
                   ==================================================== */

                schedulerLogId =
                    await startSchedulerLog(
                        connection,
                        stage
                    );


                /* ====================================================
                   2. RUN SERVICE ESCALATION
                   ==================================================== */

                const serviceEscalationResult =
                    await runServiceEscalationProcedure(
                        connection
                    );


                console.log(
                    'Service escalation engine completed:',
                    JSON.stringify(
                        serviceEscalationResult
                    )
                );


                const serviceEscalationsCreated =
                    extractEscalationsCreated(
                        serviceEscalationResult
                    );


                escalationsCreated +=
                    serviceEscalationsCreated;


                console.log(
                    'Service escalations created:',
                    serviceEscalationsCreated
                );


                /* ====================================================
                   3. RUN FOOD ESCALATION
                   ==================================================== */

                const foodEscalationResult =
                    await runFoodEscalationProcedure(
                        connection
                    );


                console.log(
                    'Food escalation engine completed:',
                    JSON.stringify(
                        foodEscalationResult
                    )
                );


                const foodEscalationsCreated =
                    extractEscalationsCreated(
                        foodEscalationResult
                    );


                escalationsCreated +=
                    foodEscalationsCreated;


                console.log(
                    'Food escalations created:',
                    foodEscalationsCreated
                );


                /* ====================================================
                   4. FIREBASE
                   ==================================================== */

                const firebaseReady =
                    initializeFirebase();


                if (!firebaseReady) {

                    console.warn(
                        'Firebase unavailable.'
                    );


                    /*
                     * Notifications remain PENDING.
                     *
                     * Next EventBridge execution will retry them.
                     */

                    const pendingRows =
                        await getPendingNotifications(
                            connection
                        );


                    notificationsPending =
                        pendingRows.length;


                    await completeSchedulerLog(
                        connection,
                        schedulerLogId,
                        'SUCCESS',
                        'Escalation completed. Firebase unavailable; notifications remain pending.',
                        escalationsCreated,
                        notificationsPending,
                        notificationsSent,
                        notificationsFailed
                    );


                } else {


                    /* =================================================
                       5. GET PENDING NOTIFICATIONS
                       ================================================= */

                    const pendingRows =
                        await getPendingNotifications(
                            connection
                        );


                    notificationsPending =
                        pendingRows.length;


                    console.log(
                        'Pending notifications:',
                        notificationsPending
                    );


                    /* =================================================
                       6. SEND FCM
                       ================================================= */

                    for (
                        const row
                        of pendingRows
                    ) {

                        const result =
                            await sendEscalationNotification(
                                connection,
                                row
                            );


                        notificationsSent +=
                            result.sent;


                        notificationsFailed +=
                            result.failed;


                        /*
                         * IMPORTANT:
                         *
                         * Do NOT increment escalationsCreated here.
                         *
                         * One escalation creates an escalation_log row,
                         * and a pending notification is created from it.
                         *
                         * Therefore the authoritative escalation count
                         * comes from the DB procedure result, not from
                         * the number of notifications sent.
                         */
                    }


                    /* =================================================
                       7. COMPLETE SCHEDULER LOG
                       ================================================= */

                    await completeSchedulerLog(
                        connection,
                        schedulerLogId,

                        notificationsFailed > 0
                            ? 'PARTIAL'
                            : 'SUCCESS',

                        notificationsFailed > 0
                            ? 'Scheduler completed with notification failures'
                            : 'Scheduler completed successfully',

                        escalationsCreated,

                        notificationsPending,

                        notificationsSent,

                        notificationsFailed
                    );
                }


                /* ====================================================
                   8. FINAL RESPONSE
                   ==================================================== */

                const response = {

                    STATUS:
                        'S',

                    MESSAGE:
                        'Escalation scheduler completed',

                    SCHEDULER_LOG_ID:
                        schedulerLogId,

                    ESCALATIONS_CREATED:
                        escalationsCreated,

                    NOTIFICATIONS_PENDING:
                        notificationsPending,

                    NOTIFICATIONS_SENT:
                        notificationsSent,

                    NOTIFICATIONS_FAILED:
                        notificationsFailed,

                    STAGE:
                        stage,

                    RUN_AT:
                        new Date().toISOString()
                };


                console.log(
                    'Scheduler response:',
                    JSON.stringify(
                        response
                    )
                );


                /* ====================================================
                   CLOSE CONNECTION
                   ==================================================== */

                connection.destroy();


                callback(
                    null,
                    response
                );


            } catch (error) {

                console.error(
                    'Escalation scheduler failed:',
                    error
                );


                /* ====================================================
                   UPDATE FAILED SCHEDULER LOG
                   ==================================================== */

                if (schedulerLogId) {

                    try {

                        await completeSchedulerLog(
                            connection,

                            schedulerLogId,

                            'FAILED',

                            error.message,

                            escalationsCreated,

                            notificationsPending,

                            notificationsSent,

                            notificationsFailed
                        );

                    } catch (logError) {

                        console.error(
                            'Failed to update scheduler log:',
                            logError
                        );
                    }
                }


                connection.destroy();


                callback(
                    error
                );
            }
        }
    );
};
