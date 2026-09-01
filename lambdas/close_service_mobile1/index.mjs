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
            '✅ Food Order Delivered';

        const body =
            serviceData.food_order_number
                ? `Order #${serviceData.food_order_number} has been delivered`
                : serviceData.order_number
                    ? `Order #${serviceData.order_number} has been delivered`
                    : 'Your food order has been delivered';

        /*
         * SAME TV NOTIFICATION TYPE
         * USED BY update_food_order_mobile1
         *
         * IMPORTANT: order_status must be 'delivered' (lowercase)
         * because the TV reads order_status and maps:
         *   delivered → Order Delivered 🍽️
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
                    serviceData.food_order_number ||
                    serviceData.order_number ||
                    ''
                ),

                order_status: 'delivered',

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

                action_performed: 'CLOSED',

                cancel_reason: ''
            },

            android: {
                priority: 'high'
            }
        };

        const response =
            await messaging.send(payload);

        console.log(
            'TV close notification sent:',
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
            'TV close notification error:',
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
 * Sends TASK_CLOSED to all active staff in the department
 * via firebase-key.json (mobile project).
 *
 * MUST include notification: { title, body } so Android/iOS
 * shows a tray notification when the app is backgrounded
 * or killed — WebSocket only works when the app is open.
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
            '🔒 Service Request Closed';

        const body =
            serviceData.service_request_id
                ? `Request #${serviceData.service_request_id} has been closed by ${serviceData.closed_by_user_name || 'a staff member'}`
                : 'A service request has been closed';

        const payload = {
            tokens,

            notification: {
                title,
                body
            },

            data: {
                type: 'TASK_CLOSED',

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

                closed_by_user_id: String(
                    serviceData.closed_by_user_id || ''
                ),

                closed_by_user_name: String(
                    serviceData.closed_by_user_name || ''
                ),

                closed_at: String(
                    serviceData.closed_at || ''
                ),

                food_order_summary_id: String(
                    serviceData.food_order_summary_id || ''
                ),

                food_order_number: String(
                    serviceData.food_order_number || ''
                ),

                status: 'closed',

                action_performed: 'CLOSED'
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
            'Mobile staff close notification result:',
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
            'Mobile staff close notification error:',
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
                    'CALL ScreenSync.close_service_mobile1(?, @p_out_mssg_flg, @p_out_mssg)',
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
                                 * = closed service request
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
                                    'Closed service request:',
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
                                                    'Closed',
                                                new_status:
                                                    'Closed',
                                                action_performed:
                                                    'CLOSED'
                                            }
                                        );
                                }

                                /* ================= MOBILE STAFF NOTIFICATION ================= */

                                let mobile_notification_stats =
                                    emptyNotificationStats();

                                /*
                                 * Send TASK_CLOSED to all staff in the
                                 * department so their phones receive the
                                 * push in background and killed state.
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
                                                'TASK_CLOSED',

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

                                            closed_by_user_id:
                                                String(
                                                    base.closed_by_user_id ||
                                                    ''
                                                ),

                                            action_performed:
                                                'CLOSED'
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

                                            closed:
                                                base.closed,

                                            closed_by_user_id:
                                                base.closed_by_user_id,

                                            closed_by_user_name:
                                                base.closed_by_user_name,

                                            closed_at:
                                                base.closed_at,

                                            accepted_at:
                                                base.accepted_at,

                                            accepted_by_user_id:
                                                base.accepted_by_user_id,

                                            accepted_by_user_name:
                                                base.accepted_by_user_name,

                                            food_order_summary_id:
                                                base.food_order_summary_id,

                                            food_order_number:
                                                base.food_order_number,

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

                                            food_order_status:
                                                base.food_order_status,

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
