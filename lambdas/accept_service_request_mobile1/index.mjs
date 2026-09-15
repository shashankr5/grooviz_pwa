'use strict';

import mysql from 'mysql';
import fs from 'fs';
import admin from 'firebase-admin';
import path from 'path';
import { fileURLToPath } from 'url';
import { getMessaging } from 'firebase-admin/messaging';

/* ================= WEBSOCKET ================= */

const WS_API_URL =
    "https://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production";

const broadcastWsEvent = async (enterpriseId, payload) => {
    try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 2000);

        const resp = await fetch(`${WS_API_URL}/@connections`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                action: 'broadcast',
                enterprise_id: String(enterpriseId),
                payload
            }),
            signal: controller.signal
        });

        clearTimeout(timeout);

        console.log('WS broadcast status:', resp.status);
    } catch (e) {
        console.warn('WS broadcast failed:', e.message);
    }
};

/* ================= PATH ================= */

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/* ================= TV FIREBASE ================= */

let tvFirebaseApp = null;

const initializeTvFirebase = () => {
    try {
        const tvKeyPath = path.join(
            __dirname,
            'firebase-key_tv.json'
        );

        if (!tvFirebaseApp && fs.existsSync(tvKeyPath)) {
            const tvServiceAccount = JSON.parse(
                fs.readFileSync(tvKeyPath, 'utf8')
            );

            tvFirebaseApp = admin.initializeApp(
                {
                    credential: admin.credential.cert(
                        tvServiceAccount
                    )
                },
                'tvApp'
            );

            console.log('TV Firebase initialized');
        } else if (!fs.existsSync(tvKeyPath)) {
            console.warn(
                'firebase-key_tv.json not found'
            );
        }
    } catch (err) {
        console.error(
            'TV Firebase initialization error:',
            err
        );
    }
};

/* ================= MOBILE FIREBASE ================= */

let mobileFirebaseApp = null;

const initializeMobileFirebase = () => {
    try {
        const mobileKeyPath = path.join(
            __dirname,
            'firebase-key.json'
        );

        if (!mobileFirebaseApp && fs.existsSync(mobileKeyPath)) {
            const mobileServiceAccount = JSON.parse(
                fs.readFileSync(mobileKeyPath, 'utf8')
            );

            mobileFirebaseApp = admin.initializeApp(
                {
                    credential: admin.credential.cert(
                        mobileServiceAccount
                    )
                },
                'mobileApp'
            );

            console.log('Mobile Firebase initialized');
        } else if (!fs.existsSync(mobileKeyPath)) {
            console.warn(
                'firebase-key.json not found'
            );
        }
    } catch (err) {
        console.error(
            'Mobile Firebase initialization error:',
            err
        );
    }
};

/* ================= NOTIFICATION STATS ================= */

const emptyNotificationStats = () => ({
    sent: 0,
    failed: 0,
    totalUsers: 0,
    users: []
});

/* ================= TV NOTIFICATION ================= */

const sendTvNotification = async (serviceData) => {
    try {
        initializeTvFirebase();

        if (!tvFirebaseApp) {
            console.warn(
                'TV Firebase is not initialized'
            );

            return emptyNotificationStats();
        }

        if (
            !serviceData.device_token ||
            !String(serviceData.device_token).trim()
        ) {
            console.warn(
                'No device token found for TV'
            );

            return emptyNotificationStats();
        }

        const messaging =
            getMessaging(tvFirebaseApp);

        const title =
            '🚚 Order On The Way';

        const body =
            serviceData.order_number
                ? `Order #${serviceData.order_number} is on the way`
                : 'Your food order is on the way';

        /*
         * SAME TV NOTIFICATION TYPE
         * USED BY update_food_order_mobile1
         */

        const payload = {
            token: String(
                serviceData.device_token
            ).trim(),

            data: {
                type: 'FOOD_ORDER_STATUS',

                title,
                body,

                order_number: String(
                    serviceData.order_number || ''
                ),

                order_status: 'accepted',

                summary_id: String(
                    serviceData.food_order_summary_id ||
                    ''
                ),

                device_id: String(
                    serviceData.device_id || ''
                ),

                device_name: String(
                    serviceData.device_name || ''
                ),

                guest_id: String(
                    serviceData.guest_id || ''
                ),

                guest_name: String(
                    serviceData.guest_name || ''
                ),

                service_request_id: String(
                    serviceData.service_request_id || ''
                ),

                department_id: String(
                    serviceData.department_id || ''
                ),

                department_name: String(
                    serviceData.department_name || ''
                ),

                action_performed: 'ACCEPTED',

                cancel_reason: ''
            },

            android: {
                priority: 'high'
            }
        };

        const response =
            await messaging.send(payload);

        console.log(
            'TV accept notification sent:',
            response
        );

        return {
            sent: 1,
            failed: 0,
            totalUsers: 1,
            users: [
                {
                    device_id: String(
                        serviceData.device_id || ''
                    ),
                    device_name:
                        serviceData.device_name || null,
                    success: true,
                    error: null
                }
            ]
        };

    } catch (err) {
        console.error(
            'TV accept notification error:',
            err
        );

        return {
            sent: 0,
            failed: 1,
            totalUsers: 1,
            users: [
                {
                    device_id: String(
                        serviceData.device_id || ''
                    ),
                    device_name:
                        serviceData.device_name || null,
                    success: false,
                    error: err.message
                }
            ]
        };
    }
};

/* ================= MOBILE STAFF NOTIFICATION ================= */

/*
 * Sends SERVICE_TASK_ACCEPTED to all active staff
 * in the department via firebase-key.json (mobile project).
 * "Data-only ON PURPOSE — a notification block would stop Android from waking
 * the background handler in background/killed, so the stop-alert code wouldn't run.
 * title/body are inside data; the app renders the tray notification itself if needed."
 *
 * stop_alert: 'true' tells the app to stop the siren IMMEDIATELY when this
 * message is received, without waiting for the network reconcile. This is
 * critical for the background/killed state where the execution window is short.
 *
 * Tokens are fetched from user_fcm_tokens joined through
 * user_role_dept_mapping — same pattern used by
 * update_food_order_mobile1 and add_service_booking_tv.
 */

const sendMobileStaffNotification = async (
    connection,
    serviceData
) => {
    try {
        initializeMobileFirebase();

        if (!mobileFirebaseApp) {
            console.warn(
                'Mobile Firebase is not initialized'
            );

            return emptyNotificationStats();
        }

        const staffRows = await new Promise(
            (resolve, reject) => {
                connection.query(
                    `SELECT DISTINCT
                         u.user_id,
                         u.full_name AS username,
                         u.email,
                         uft.fcm_token AS token_app
                     FROM users u
                     INNER JOIN user_role_dept_mapping urdm
                         ON urdm.user_id       = u.user_id
                        AND urdm.enterprise_id = ?
                        AND urdm.department_id = ?
                        AND urdm.is_active     = 1
                        AND urdm.delete_flag   = 'N'
                     INNER JOIN user_fcm_tokens uft
                         ON uft.user_id    = u.user_id
                        AND uft.status     = 'Active'
                        AND uft.fcm_token IS NOT NULL
                        AND TRIM(uft.fcm_token) <> ''
                        AND uft.fcm_token <> 'web_pwa_client_token'
                     WHERE u.status    = 'Active'
                       AND u.user_type = 'Mobile'`,
                    [
                        serviceData.enterprise_id,
                        serviceData.department_id
                    ],
                    (err, rows) =>
                        err ? reject(err) : resolve(rows)
                );
            }
        );

        const validStaff = (staffRows || []).filter(
            u =>
                u.token_app &&
                String(u.token_app).trim()
        );

        if (!validStaff.length) {
            console.log(
                'No staff with FCM tokens found for department',
                serviceData.department_id
            );

            return emptyNotificationStats();
        }

        const messaging =
            getMessaging(mobileFirebaseApp);

        const notificationUsers =
            validStaff.slice(0, 500);

        const tokens =
            notificationUsers.map(
                u => String(u.token_app).trim()
            );

        const title =
            '✅ Service Request Accepted';

        const body =
            serviceData.service_request_id
                ? `Request #${serviceData.service_request_id} has been accepted by ${serviceData.accepted_by_user_name || 'a staff member'}`
                : 'A service request has been accepted';

        const payload = {
            tokens,

            data: {
                type: 'SERVICE_TASK_ACCEPTED',

                // ── CRITICAL: Tells app to stop siren immediately ──
                // This ensures the siren stops even if the background
                // isolate is killed before the network reconcile completes.
                stop_alert: 'true',

                title,
                body,

                service_request_id: String(
                    serviceData.service_request_id || ''
                ),

                enterprise_id: String(
                    serviceData.enterprise_id || ''
                ),

                department_id: String(
                    serviceData.department_id || ''
                ),

                department_name: String(
                    serviceData.department_name || ''
                ),

                department_type: String(
                    serviceData.department_type || ''
                ),

                accepted_by_user_id: String(
                    serviceData.accepted_by_user_id || ''
                ),

                accepted_by_user_name: String(
                    serviceData.accepted_by_user_name || ''
                ),

                accepted_at: String(
                    serviceData.accepted_at || ''
                ),

                status: 'accepted',

                action_performed: 'ACCEPTED',

                // ✅ ADDED: so client can detect food delivery and stop delivery alert
                food_order_summary_id: String(serviceData.food_order_summary_id || ''),
                question: String(serviceData.question || '')
            },

            android: {
                priority: 'high'
            }
        };

        const response =
            await messaging.sendEachForMulticast(payload);

        const usersWithStatus =
            notificationUsers.map(
                (u, index) => ({
                    user_id: u.user_id,
                    username: u.username,
                    email: u.email,

                    token_app:
                        String(u.token_app)
                            .substring(0, 20) + '...',

                    success:
                        response.responses[index]
                            ?.success || false,

                    error:
                        response.responses[index]
                            ?.error?.message || null
                })
            );

        console.log(
            'Mobile staff accept notification result:',
            response.successCount,
            response.failureCount
        );

        return {
            sent: response.successCount,
            failed: response.failureCount,
            totalUsers: notificationUsers.length,
            users: usersWithStatus
        };

    } catch (err) {
        console.error(
            'Mobile staff accept notification error:',
            err
        );

        return emptyNotificationStats();
    }
};

/* ================= RESPONSE FORMATTER ================= */

const formatResult = (
    status,
    message,
    data = {}
) => ({
    RESULT: [
        {
            status,
            message,
            ...data
        }
    ]
});

/* ================= MAIN HANDLER ================= */

export const handler = (
    event,
    context,
    callback
) => {

    context.callbackWaitsForEmptyEventLoop = false;

    /* ================= STAGE ================= */

    if (!event.stage) {
        return callback(
            null,
            formatResult(
                'E',
                'Missing stage parameter'
            )
        );
    }

    const configFile =
        event.stage === 'prod'
            ? '/opt/nodejs/node_modules/dbConfig.json'
            : '/opt/nodejs/node_modules/dbConfig_dev.json';

    try {

        /* ================= DB CONFIG ================= */

        const dbconfig =
            JSON.parse(
                fs.readFileSync(
                    configFile,
                    'utf8'
                )
            );

        /* ================= DB CONNECTION ================= */

        const pool =
            mysql.createPool({
                host: dbconfig.dbhost,
                user: dbconfig.dbuser,
                password: dbconfig.dbpassword,
                database: dbconfig.dbname,
                connectionLimit: 5
            });

        pool.getConnection(
            (err, connection) => {

                if (err) {
                    return callback(
                        null,
                        formatResult(
                            'E',
                            err.message
                        )
                    );
                }

                const jsonRequest =
                    JSON.stringify(event);

                /* ================= CALL PROCEDURE ================= */

                connection.query(
                    'CALL ScreenSync.accept_service_request_mobile1(?, @p_out_mssg_flg, @p_out_mssg)',
                    [jsonRequest],

                    async (
                        procedureError,
                        results
                    ) => {

                        if (procedureError) {
                            connection.destroy();

                            return callback(
                                null,
                                formatResult(
                                    'E',
                                    procedureError.message
                                )
                            );
                        }

                        /* ================= OUT PARAMETERS ================= */

                        connection.query(
                            'SELECT @p_out_mssg_flg AS flag, @p_out_mssg AS message',

                            async (
                                outError,
                                out
                            ) => {

                                if (outError) {
                                    connection.destroy();

                                    return callback(
                                        null,
                                        formatResult(
                                            'E',
                                            outError.message
                                        )
                                    );
                                }

                                const flag =
                                    out[0]?.flag;

                                const message =
                                    out[0]?.message;

                                /*
                                 * results[0]
                                 * = procedure status
                                 *
                                 * results[1]
                                 * = accepted service request
                                 */

                                const serviceRows =
                                    results?.[1] || [];

                                const base =
                                    serviceRows[0] || {};

                                console.log(
                                    'Procedure flag:',
                                    flag
                                );

                                console.log(
                                    'Procedure message:',
                                    message
                                );

                                console.log(
                                    'Accepted service request:',
                                    base
                                );

                                /* ================= TV NOTIFICATION ================= */

                                let notification_stats =
                                    emptyNotificationStats();

                                /*
                                 * ONLY FOOD SERVICE REQUEST
                                 *
                                 * Normal service:
                                 * food_order_summary_id = NULL
                                 * => NO Firebase
                                 *
                                 * Food service:
                                 * food_order_summary_id > 0
                                 * => Firebase
                                 */

                                if (
                                    flag === 'S' &&
                                    base.food_order_summary_id &&
                                    Number(
                                        base.food_order_summary_id
                                    ) > 0 &&
                                    base.device_token &&
                                    String(
                                        base.device_token
                                    ).trim()
                                ) {

                                    notification_stats =
                                        await sendTvNotification(
                                            {
                                                ...base,
                                                status:
                                                    'In Progress',
                                                new_status:
                                                    'accepted',
                                                action_performed:
                                                    'ACCEPTED'
                                            }
                                        );
                                }

                                /* ================= MOBILE STAFF NOTIFICATION ================= */

                                let mobile_notification_stats =
                                    emptyNotificationStats();

                                /*
                                 * Send SERVICE_TASK_ACCEPTED to all staff
                                 * in the department so their phones receive
                                 * the push in background and killed state.
                                 *
                                 * The payload includes stop_alert: 'true'
                                 * which tells the app to stop the siren
                                 * immediately upon receipt.
                                 *
                                 * Applies to ALL service requests —
                                 * both normal and food-linked.
                                 */

                                if (
                                    flag === 'S' &&
                                    base.enterprise_id &&
                                    base.department_id
                                ) {

                                    mobile_notification_stats =
                                        await sendMobileStaffNotification(
                                            connection,
                                            base
                                        );
                                }

                                /* ================= WEBSOCKET ================= */

                                if (
                                    flag === 'S' &&
                                    base.enterprise_id
                                ) {

                                    await broadcastWsEvent(
                                        base.enterprise_id,
                                        {
                                            type:
                                                'SERVICE_TASK_ACCEPTED',

                                            service_request_id:
                                                String(
                                                    base.service_request_id ||
                                                    ''
                                                ),

                                            enterprise_id:
                                                String(
                                                    base.enterprise_id ||
                                                    ''
                                                ),

                                            department_id:
                                                String(
                                                    base.department_id ||
                                                    ''
                                                ),

                                            accepted_by_user_id:
                                                String(
                                                    base.accepted_by_user_id ||
                                                    ''
                                                ),

                                            accepted_by_user_name:
                                                base.accepted_by_user_name ||
                                                null,

                                            action_performed:
                                                'ACCEPTED'
                                        }
                                    );
                                }

                                connection.destroy();

                                /* ================= RESPONSE ================= */

                                return callback(
                                    null,
                                    formatResult(
                                        flag,
                                        message,
                                        {
                                            service_request_id:
                                                base.service_request_id,

                                            enterprise_id:
                                                base.enterprise_id,

                                            department_id:
                                                base.department_id,

                                            department_name:
                                                base.department_name,

                                            department_type:
                                                base.department_type,

                                            status:
                                                base.status,

                                            accepted_at:
                                                base.accepted_at,

                                            accepted_by_user_id:
                                                base.accepted_by_user_id,

                                            accepted_by_user_name:
                                                base.accepted_by_user_name,

                                            food_order_summary_id:
                                                base.food_order_summary_id,

                                            order_number:
                                                base.order_number,

                                            device_id:
                                                base.device_id,

                                            device_name:
                                                base.device_name,

                                            device_location:
                                                base.device_location,

                                            guest_id:
                                                base.guest_id,

                                            guest_name:
                                                base.guest_name,

                                            device_token:
                                                base.device_token,

                                            notification_stats,

                                            mobile_notification_stats
                                        }
                                    )
                                );
                            }
                        );
                    }
                );
            }
        );

    } catch (error) {

        return callback(
            null,
            formatResult(
                'E',
                error.message
            )
        );
    }
};
