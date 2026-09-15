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

/* ================= FIREBASE ================= */

let tvFirebaseApp = null;
let mobileFirebaseApp = null;

const initializeFirebase = () => {
    try {

        /* ================= TV FIREBASE ================= */

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

            console.log('✅ TV Firebase initialized');

        } else if (!fs.existsSync(tvKeyPath)) {

            console.warn(
                '⚠️ firebase-key_tv.json not found'
            );
        }


        /* ================= MOBILE FIREBASE ================= */

        const mobileKeyPath = path.join(
            __dirname,
            'firebase-key.json'
        );

        if (!mobileFirebaseApp && fs.existsSync(mobileKeyPath)) {

            const mobileServiceAccount = JSON.parse(
                fs.readFileSync(
                    mobileKeyPath,
                    'utf8'
                )
            );

            mobileFirebaseApp = admin.initializeApp(
                {
                    credential: admin.credential.cert(
                        mobileServiceAccount
                    )
                },
                'mobileApp'
            );

            console.log(
                '✅ Mobile Firebase initialized'
            );

        } else if (!fs.existsSync(mobileKeyPath)) {

            console.warn(
                '⚠️ firebase-key.json not found'
            );
        }

    } catch (err) {

        console.error(
            '❌ Firebase initialization error:',
            err
        );
    }
};

/* ================= EMPTY NOTIFICATION ================= */

const emptyNotificationStats = () => ({
    sent: 0,
    failed: 0,
    totalUsers: 0,
    users: []
});


/* ================= TV NOTIFICATION ================= */

const sendTvNotification = async (orderData) => {

    try {

        initializeFirebase();

        if (!tvFirebaseApp) {

            console.warn(
                'TV Firebase is not initialized'
            );

            return emptyNotificationStats();
        }

        if (
            !orderData.device_token ||
            !String(orderData.device_token).trim()
        ) {

            console.warn(
                'No device token found for TV'
            );

            return emptyNotificationStats();
        }

        const messaging =
            getMessaging(tvFirebaseApp);

        const status =
            orderData.new_status ||
            orderData.order_status;

        let title = '🍽️ Food Order Updated';

        let body =
            `Order #${orderData.order_number} is ${status}`;


        if (status === 'Ready') {

            title = '🍽️ Food Order Ready For Delivery';

            body =
                `Order #${orderData.order_number} is ready`;

        } else if (status === 'Preparing') {

            title = '👨‍🍳 Food Order Preparing';

            body =
                `Order #${orderData.order_number} is being prepared`;

        } else if (status === 'Delivered') {

            title = '✅ Food Order Delivered';

            body =
                `Order #${orderData.order_number} has been delivered`;

        } else if (status === 'Cancelled') {

            title = '❌ Food Order Cancelled';

            body =
                `Order #${orderData.order_number} has been cancelled`;
        }


        /* =========================================================
           TV FCM PAYLOAD

           IMPORTANT:
           Data-only message.
           NO notification block.
        ========================================================= */

        const payload = {

            token: String(
                orderData.device_token
            ).trim(),

            data: {

                type: 'FOOD_ORDER_STATUS',

                title,
                body,

                order_number: String(
                    orderData.order_number || ''
                ),

                order_status: String(
                    status || ''
                ),

                summary_id: String(
                    orderData.summary_id || ''
                ),

                device_id: String(
                    orderData.device_id || ''
                ),

                device_name: String(
                    orderData.device_name || ''
                ),

                guest_id: String(
                    orderData.guest_id || ''
                ),

                guest_name: String(
                    orderData.guest_name || ''
                ),

                service_request_id: String(
                    orderData.service_request_id || ''
                ),

                cancel_reason: String(
                    orderData.cancel_reason || ''
                )
            },

            android: {
                priority: 'high'
            }
        };


        const response =
            await messaging.send(payload);

        console.log(
            '✅ TV notification sent:',
            response
        );

        return {
            sent: 1,
            failed: 0,
            totalUsers: 1,
            users: [
                {
                    device_id: String(
                        orderData.device_id || ''
                    ),

                    device_name:
                        orderData.device_name || null,

                    success: true,

                    error: null
                }
            ]
        };

    } catch (err) {

        console.error(
            '❌ TV notification error:',
            err
        );

        return {
            sent: 0,
            failed: 1,
            totalUsers: 1,
            users: [
                {
                    device_id: String(
                        orderData.device_id || ''
                    ),

                    device_name:
                        orderData.device_name || null,

                    success: false,

                    error: err.message
                }
            ]
        };
    }
};


/* ================= ROOM SERVICE MOBILE NOTIFICATION ================= */

const sendRoomServiceNotifications = async (
    users,
    orderData
) => {

    try {

        initializeFirebase();

        if (!mobileFirebaseApp) {

            console.warn(
                'Mobile Firebase is not initialized'
            );

            return emptyNotificationStats();
        }

        if (!users || !users.length) {

            console.log(
                'No Room Service users found'
            );

            return emptyNotificationStats();
        }

        const validUsers = users.filter(
            u =>
                u.token_app &&
                String(u.token_app).trim() &&
                String(u.token_app).trim() !== 'web_pwa_client_token'
        );

        if (!validUsers.length) {

            console.log(
                'No Room Service users with valid FCM tokens'
            );

            return emptyNotificationStats();
        }

        const messaging =
            getMessaging(mobileFirebaseApp);

        /*
         * Firebase multicast maximum = 500 tokens
         */

        const notificationUsers =
            validUsers.slice(0, 500);

        const tokens =
            notificationUsers.map(
                u =>
                    String(u.token_app).trim()
            );

        const firstUser =
            notificationUsers[0];

        const title =
            '🍽️ Food Order Ready For Delivery';

        const body =
            `Food order #${firstUser.order_number} is ready for delivery to room ${firstUser.room_id}`;


        /*
         * Data-only ON PURPOSE — a notification block would stop Android
         * from waking the background handler in background/killed.
         * title/body are inside data; the app renders the banner itself.
         */

        const payload = {

            tokens,

            data: {

                type: 'FOOD_ORDER_STATUS',

                title,
                body,

                new_status: String(orderData.new_status || orderData.order_status || ''),

                order_number: String(
                    firstUser.order_number || ''
                ),

                service_request_id: String(
                    firstUser.service_request_id || ''
                ),

                room_id: String(
                    firstUser.room_id || ''
                ),

                department_id: String(
                    firstUser.department_id || ''
                ),

                department_name: String(
                    firstUser.department_name || ''
                ),

                completion_minutes: String(
                    firstUser.completion_minutes || ''
                )
            },

            android: {
                priority: 'high'
            }
        };


        const response =
            await messaging.sendEachForMulticast(
                payload
            );


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
                            ?.error?.message || null,

                    sent:
                        response.responses[index]
                            ?.success || false
                })
            );


        console.log(
            'Room Service notification result:',
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
            '❌ Room Service notification error:',
            err
        );

        return {
            sent: 0,
            failed: users?.length || 0,
            totalUsers: users?.length || 0,

            users: (users || []).map(
                u => ({
                    user_id: u.user_id,
                    username: u.username,
                    email: u.email,

                    token_app:
                        u.token_app
                            ? String(u.token_app)
                                .substring(0, 20) + '...'
                            : null,

                    success: false,
                    error: err.message,
                    sent: false
                })
            )
        };
    }
};

/* ==========================================================
   MOBILE STAFF STOP ALERT BROADCAST

   Looks up active mobile staff in the supplied department. The
   food order device_token is the room TV token and must not be
   used as a mobile stop-alert target.
========================================================== */
const sendMobileStaffStopAlert = async (
    connection,
    orderData
) => {

    try {

        initializeFirebase();

        if (!mobileFirebaseApp) {
            console.warn(
                'Mobile Firebase is not initialized'
            );

            return emptyNotificationStats();
        }

        if (!orderData.enterprise_id || !orderData.department_id) {
            console.warn(
                'Skipping food stop alert: missing enterprise_id or department_id',
                {
                    enterprise_id: orderData.enterprise_id,
                    department_id: orderData.department_id
                }
            );
            return emptyNotificationStats();
        }

        const staffRows = await new Promise((resolve, reject) => {
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
                [orderData.enterprise_id, orderData.department_id],
                (err, rows) => err ? reject(err) : resolve(rows)
            );
        });

        const validUsers = (staffRows || []).filter(
            user => user.token_app && String(user.token_app).trim()
        );

        if (!validUsers.length) {
            console.log(
                'No Food department staff with FCM tokens',
                orderData.department_id
            );
            return emptyNotificationStats();
        }

        const messaging =
            getMessaging(mobileFirebaseApp);

        const notificationUsers =
            validUsers.slice(0, 500);

        const payload = {
            tokens: notificationUsers.map(
                u => String(u.token_app).trim()
            ),

            data: {
                type: 'FOOD_ORDER_STATUS',
                stop_alert: 'true',
                title: 'Food Order Alert Stopped',
                body: `Order #${orderData.order_number} is no longer pending`,
                order_status: String(
                    orderData.new_status || orderData.order_status || ''
                ),
                new_status: String(
                    orderData.new_status || orderData.order_status || ''
                ),
                action_performed: String(
                    orderData.new_status || orderData.order_status || ''
                ).toUpperCase(),
                summary_id: String(orderData.summary_id || ''),
                order_id: String(orderData.summary_id || ''),
                food_order_summary_id: String(orderData.summary_id || ''),
                enterprise_id: String(orderData.enterprise_id || ''),
                department_id: String(orderData.department_id || ''),
                department_name: String(orderData.department_name || ''),
                order_number: String(orderData.order_number || '')
            },

            android: {
                priority: 'high'
            }
        };

        const response =
            await messaging.sendEachForMulticast(payload);

        return {
            sent: response.successCount,
            failed: response.failureCount,
            totalUsers: notificationUsers.length,
            users: notificationUsers.map((u, index) => ({
                user_id: u.user_id,
                username: u.username,
                email: u.email,
                success: response.responses[index]?.success || false,
                error: response.responses[index]?.error?.message || null,
                sent: response.responses[index]?.success || false
            }))
        };

    } catch (err) {

        console.error(
            '❌ Mobile staff stop alert error:',
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

    context.callbackWaitsForEmptyEventLoop =
        false;


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
                    'CALL ScreenSync.update_food_order_mobile1(?, @p_out_mssg_flg, @p_out_mssg)',
                    [jsonRequest],

                    async (
                        err,
                        results
                    ) => {

                        if (err) {

                            connection.destroy();

                            return callback(
                                null,
                                formatResult(
                                    'E',
                                    err.message
                                )
                            );
                        }


                        /* ================= GET OUT PARAMETERS ================= */

                        connection.query(
                            'SELECT @p_out_mssg_flg AS flag, @p_out_mssg AS message',

                            async (
                                err2,
                                out
                            ) => {

                                if (err2) {

                                    connection.destroy();

                                    return callback(
                                        null,
                                        formatResult(
                                            'E',
                                            err2.message
                                        )
                                    );
                                }


                                const flag =
                                    out[0]?.flag;

                                const message =
                                    out[0]?.message;


                                /*
                                 * Result sets:
                                 *
                                 * results[0] = status result
                                 * results[1] = main order result
                                 * results[2] = Room Service users
                                 */

                                const resultSets = (results || [])
                                    .filter(result => Array.isArray(result) && result.length > 0);

                                const roomServiceUsers = resultSets.find(rows =>
                                    rows.some(row => Object.prototype.hasOwnProperty.call(row, 'token_app'))
                                ) || [];

                                const orderRows = resultSets.find(rows =>
                                    rows !== roomServiceUsers &&
                                    rows.some(row =>
                                        Object.prototype.hasOwnProperty.call(row, 'order_number') ||
                                        Object.prototype.hasOwnProperty.call(row, 'device_token')
                                    )
                                ) || results?.[1] || [];

                                const base =
                                    orderRows[0] || {};


                                console.log(
                                    'Procedure flag:',
                                    flag
                                );

                                console.log(
                                    'Procedure message:',
                                    message
                                );

                                console.log(
                                    'Main order:',
                                    base
                                );

                                console.log(
                                    'Room Service users:',
                                    roomServiceUsers.length
                                );


                                /* ================= TV NOTIFICATION ================= */

                                let notification_stats =
                                    emptyNotificationStats();


                                /* ================= MOBILE NOTIFICATION ================= */

                                let mobile_notification_stats =
                                    emptyNotificationStats();

                                let food_stop_alert_stats =
                                    emptyNotificationStats();


                                const normalizedStatus = String(
                                    event.status ||
                                    base.new_status ||
                                    base.order_status ||
                                    ''
                                ).trim().toLowerCase();

                                if (flag === 'S') {

                                    /*
                                     * TV notification.
                                     *
                                     * Data-only.
                                     */

                                    if (
                                        base.device_token &&
                                        String(
                                            base.device_token
                                        ).trim()
                                    ) {

                                        notification_stats =
                                            await sendTvNotification(
                                                base
                                            );
                                    }


                                    /*
                                     * Room Service notification.
                                     *
                                     * ONLY when food order becomes Ready.
                                     */

                                    if (normalizedStatus === 'ready') {

                                        mobile_notification_stats =
                                            await sendRoomServiceNotifications(
                                                roomServiceUsers,
                                                base
                                            );
                                    } else {
                                        console.log(
                                            'Skipping Room Service notification; status:',
                                            normalizedStatus || '(empty)',
                                            'users:',
                                            roomServiceUsers.length
                                        );
                                    }

                                    /* ============================================
                                     * FOOD ALERT STOP
                                     *
                                     * Stop the kitchen alert on cancellation.
                                     * Ready is included as a defensive no-op for
                                     * orders that bypassed the accept endpoint.
                                     * ============================================ */

                                    if (
                                        normalizedStatus === 'cancelled' ||
                                        normalizedStatus === 'ready'
                                    ) {

                                        if (
                                            base.enterprise_id &&
                                            base.department_id
                                        ) {
                                            food_stop_alert_stats =
                                                await sendMobileStaffStopAlert(
                                                    connection,
                                                    {
                                                        ...base,
                                                        order_status:
                                                            base.order_status || normalizedStatus,
                                                        new_status:
                                                            normalizedStatus.toUpperCase(),
                                                        action_performed:
                                                            normalizedStatus.toUpperCase()
                                                    }
                                                );
                                        } else {
                                            console.warn(
                                                'Skipping food stop alert: missing enterprise_id or department_id',
                                                {
                                                    enterprise_id: base.enterprise_id,
                                                    department_id: base.department_id
                                                }
                                            );
                                        }
                                    }


                                    /* ================= WEBSOCKET ================= */

                                    if (
                                        base.enterprise_id
                                    ) {

                                        await broadcastWsEvent(
                                            base.enterprise_id,
                                            {
                                                type:
                                                    'FOOD_ORDER_STATUS',

                                                summary_id:
                                                    String(
                                                        base.summary_id || ''
                                                    ),

                                                order_number:
                                                    base.order_number,

                                                order_status:
                                                    base.order_status,

                                                new_status:
                                                    base.new_status,

                                                device_id:
                                                    String(
                                                        base.device_id || ''
                                                    ),

                                                device_name:
                                                    base.device_name || null,

                                                guest_id:
                                                    String(
                                                        base.guest_id || ''
                                                    ),

                                                service_request_id:
                                                    String(
                                                        base.service_request_id || ''
                                                    ),

                                                room_id:
                                                    String(
                                                        base.room_id || ''
                                                    )
                                            }
                                        );
                                    }
                                }


                                /* ================= CLOSE CONNECTION ================= */

                                connection.destroy();


                                /* ================= RESPONSE ================= */

                                return callback(
                                    null,
                                    formatResult(
                                        flag,
                                        message,
                                        {
                                            summary_id:
                                                base.summary_id,

                                            order_number:
                                                base.order_number,

                                            order_status:
                                                base.order_status,

                                            guest_id:
                                                base.guest_id,

                                            guest_name:
                                                base.guest_name,

                                            guest_phone:
                                                base.guest_phone,

                                            device_id:
                                                base.device_id,

                                            device_name:
                                                base.device_name,

                                            device_location:
                                                base.device_location,

                                            food_name:
                                                base.food_name,

                                            quantity:
                                                base.quantity,

                                            total_price:
                                                base.total_price,

                                            action_performed:
                                                base.action_performed,

                                            preparing_time:
                                                base.preparing_time,

                                            ready_time:
                                                base.ready_time,

                                            delivered_time:
                                                base.delivered_time,

                                            cancelled_time:
                                                base.cancelled_time,

                                            cancel_reason:
                                                base.cancel_reason,

                                            accepted_user_id:
                                                base.accepted_user_id,

                                            delivered_user_id:
                                                base.delivered_user_id,

                                            eta_time:
                                                base.eta_time,

                                            rush_hour:
                                                base.rush_hour,

                                            new_status:
                                                base.new_status,

                                            service_request_id:
                                                base.service_request_id,

                                            room_id:
                                                base.room_id,

                                            room_service_department_id:
                                                base.room_service_department_id,

                                            notification_stats,

                                            mobile_notification_stats,

                                            food_stop_alert_stats
                                        }
                                    )
                                );
                            }
                        );
                    }
                );
            }
        );

    } catch (err) {

        return callback(
            null,
            formatResult(
                'E',
                err.message
            )
        );
    }
};
