'use strict';

import mysql from 'mysql';
import fs from 'fs';
import admin from 'firebase-admin';
import path from 'path';
import { fileURLToPath } from 'url';
import { getMessaging } from 'firebase-admin/messaging';

const WS_API_URL =
    "https://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production";


const broadcastWsEvent = async (
    enterpriseId,
    payload
) => {

    try {

        const controller =
            new AbortController();

        const timeout =
            setTimeout(
                () => controller.abort(),
                2000
            );


        const resp =
            await fetch(
                `${WS_API_URL}/@connections`,
                {
                    method: 'POST',

                    headers: {
                        'Content-Type':
                            'application/json'
                    },

                    body: JSON.stringify({
                        action: 'broadcast',

                        enterprise_id:
                            String(
                                enterpriseId
                            ),

                        payload
                    }),

                    signal: controller.signal
                }
            );


        clearTimeout(timeout);

        console.log(
            'WS broadcast status:',
            resp.status
        );


        return {
            success: resp.ok,
            status: resp.status
        };

    } catch (e) {

        console.warn(
            'WS broadcast failed:',
            e.message
        );


        return {
            success: false,
            status: 0,
            error: e.message
        };
    }
};


/* ================= PATH ================= */

const __filename =
    fileURLToPath(import.meta.url);

const __dirname =
    path.dirname(__filename);


/* ================= FIREBASE ================= */

let firebaseInitialized =
    false;


const initializeFirebase = () => {

    if (firebaseInitialized)
        return;


    const serviceAccountPath =
        path.join(
            __dirname,
            'firebase-key.json'
        );


    if (!fs.existsSync(
        serviceAccountPath
    )) {

        console.warn(
            '⚠️ Firebase key not found'
        );

        return;
    }


    try {

        const serviceAccount =
            JSON.parse(
                fs.readFileSync(
                    serviceAccountPath,
                    'utf8'
                )
            );


        admin.initializeApp({
            credential:
                admin.credential.cert(
                    serviceAccount
                )
        });


        firebaseInitialized =
            true;


        console.log(
            '✅ Firebase initialized'
        );

    } catch (err) {

        console.error(
            '❌ Firebase initialization error:',
            err
        );
    }
};


/* ==========================================================
   TV ORDER ACCEPTED NOTIFICATION

   IMPORTANT:
   - Data-only
   - type = FOOD_ORDER_STATUS
   - order_status = accepted
   - NO notification block
========================================================== */

const sendOrderAcceptedNotification = async (
    deviceToken,
    orderData
) => {

    try {

        initializeFirebase();


        if (!firebaseInitialized) {

            return {
                sent: 0,
                failed: 1,
                error:
                    'Firebase not initialized'
            };
        }


        if (
            !deviceToken ||
            !deviceToken.trim()
        ) {

            console.log(
                'No device token available'
            );

            return {
                sent: 0,
                failed: 1,
                error:
                    'Device token not found'
            };
        }


        const messaging =
            getMessaging();


        const title =
            'Order Accepted';

        const body =
            `Order #${orderData.order_number} has been accepted`;


        /* ======================================================
           TV DATA-ONLY PAYLOAD
        ====================================================== */

        const payload = {

            token:
                deviceToken.trim(),

            data: {

                type:
                    'FOOD_ORDER_STATUS',

                title,

                body,

                order_number:
                    String(
                        orderData.order_number || ''
                    ),

                order_id:
                    String(
                        orderData.summary_id || ''
                    ),

                device_id:
                    String(
                        orderData.device_id || ''
                    ),

                device_name:
                    String(
                        orderData.device_name || ''
                    ),

                guest_id:
                    String(
                        orderData.guest_id || ''
                    ),


                /* IMPORTANT FOR TV */

                order_status:
                    'preparing',


                /* Keep for compatibility */

                status:
                    'Accepted',

                action_performed:
                    'ACCEPTED',

                eta_minutes:
                    String(
                        orderData.total_eta_minutes || 0
                    ),

                eta_time:
                    String(
                        orderData.eta_time || ''
                    )
            },

            android: {
                priority: 'high'
            }
        };


        const response =
            await messaging.send(
                payload
            );


        console.log(
            'ORDER_ACCEPTED FCM sent:',
            response
        );


        return {
            sent: 1,
            failed: 0,
            error: null
        };


    } catch (err) {

        console.error(
            '❌ ORDER_ACCEPTED notification error:',
            err
        );


        return {
            sent: 0,
            failed: 1,
            error:
                err.message
        };
    }
};

/* ==========================================================
   MOBILE STAFF STOP ALERT BROADCAST

   The order device_token belongs to the room TV. Mobile staff
   tokens must be loaded from the staff token tables instead.
========================================================== */
const sendMobileStaffStopAlert = async (
    connection,
    orderData
) => {

    try {

        initializeFirebase();

        if (!firebaseInitialized) {
            return { sent: 0, failed: 0, totalUsers: 0, users: [] };
        }

        if (
            !orderData.enterprise_id ||
            !orderData.department_id
        ) {
            console.warn(
                'Skipping mobile staff stop alert: missing enterprise_id or department_id',
                {
                    enterprise_id: orderData.enterprise_id,
                    department_id: orderData.department_id
                }
            );
            return { sent: 0, failed: 0, totalUsers: 0, users: [] };
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

        const validStaff = (staffRows || []).filter(
            user => user.token_app && String(user.token_app).trim()
        );

        if (!validStaff.length) {
            console.log(
                'No staff with FCM tokens in department',
                orderData.department_id
            );
            return { sent: 0, failed: 0, totalUsers: 0, users: [] };
        }

        const notificationUsers = validStaff.slice(0, 500);
        const messaging = getMessaging();
        const payload = {
            tokens: notificationUsers.map(
                user => String(user.token_app).trim()
            ),
            data: {
                type: 'FOOD_ORDER_STATUS',
                stop_alert: 'true',
                title: 'Food Order Accepted',
                body: `Order #${orderData.order_number} has been accepted`,
                food_order_summary_id: String(orderData.summary_id || ''),
                summary_id: String(orderData.summary_id || ''),
                order_id: String(orderData.summary_id || ''),
                order_number: String(orderData.order_number || ''),
                order_status: 'accepted',
                new_status: 'ACCEPTED',
                action_performed: 'ACCEPTED',
                enterprise_id: String(orderData.enterprise_id || ''),
                department_id: String(orderData.department_id || ''),
                accepted_user_id: String(orderData.accepted_user_id || ''),
                accepted_at: String(orderData.kitchen_accepted_at || '')
            },
            android: {
                priority: 'high'
            }
        };

        const response =
            await messaging.sendEachForMulticast(payload);

        const usersWithStatus = notificationUsers.map(
            (user, index) => ({
                user_id: user.user_id,
                username: user.username,
                email: user.email,
                token_app: String(user.token_app).substring(0, 20) + '...',
                success: response.responses[index]?.success || false,
                error: response.responses[index]?.error?.message || null
            })
        );

        console.log(
            'Mobile staff stop alert:',
            response.successCount,
            'sent,',
            response.failureCount,
            'failed'
        );

        return {
            sent: response.successCount,
            failed: response.failureCount,
            totalUsers: notificationUsers.length,
            users: usersWithStatus
        };

    } catch (err) {

        console.error(
            'Mobile staff stop alert error:',
            err
        );

        return { sent: 0, failed: 0, totalUsers: 0, users: [] };
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

        const dbconfig =
            JSON.parse(
                fs.readFileSync(
                    configFile,
                    'utf8'
                )
            );


        const pool =
            mysql.createPool({

                host:
                    dbconfig.dbhost,

                user:
                    dbconfig.dbuser,

                password:
                    dbconfig.dbpassword,

                database:
                    dbconfig.dbname
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


                connection.query(

                    `CALL ScreenSync.accept_food_order_mobile1(
                        ?,
                        @p_out_mssg_flg,
                        @p_out_mssg
                    )`,

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


                        connection.query(

                            `SELECT
                                @p_out_mssg_flg AS flag,
                                @p_out_mssg AS message`,

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


                                const orderRows =
                                    results?.[1] || [];

                                const base =
                                    orderRows[0] || {};


                                console.log(
                                    'Procedure status:',
                                    flag,
                                    message
                                );


                                console.log(
                                    'Procedure order result:',
                                    JSON.stringify(base)
                                );


                                let notification_stats = {

                                    sent: 0,
                                    failed: 0,
                                    totalUsers: 0,
                                    users: []
                                };

                                let mobile_stop_stats = {

                                    sent: 0,
                                    failed: 0,
                                    totalUsers: 0,
                                    users: []
                                };


                                if (flag === 'S') {

                                    /* ================= TV NOTIFICATION ================= */

                                    if (
                                        base.device_token
                                    ) {

                                        const notificationResult =
                                            await sendOrderAcceptedNotification(
                                                base.device_token,
                                                {
                                                    summary_id:
                                                        base.summary_id,

                                                    order_number:
                                                        base.order_number,

                                                    device_id:
                                                        base.device_id,

                                                    device_name:
                                                        base.device_name,

                                                    guest_id:
                                                        base.guest_id,

                                                    eta_time:
                                                        base.eta_time,

                                                    total_eta_minutes:
                                                        base.total_eta_minutes
                                                }
                                            );


                                        notification_stats = {

                                            sent:
                                                notificationResult.sent,

                                            failed:
                                                notificationResult.failed,

                                            totalUsers:
                                                1,

                                            users: [
                                                {
                                                    device_id:
                                                        base.device_id,

                                                    device_name:
                                                        base.device_name,

                                                    success:
                                                        notificationResult.sent === 1,

                                                    error:
                                                        notificationResult.error
                                                }
                                            ]
                                        };

                                    } else {

                                        console.warn(
                                            'TV notification not sent: device_token is missing'
                                        );
                                    }

                                    /* ================= MOBILE STAFF STOP ALERT ================= */

                                    const mobileStopOrderData = {
                                        ...base,
                                        enterprise_id:
                                            base.enterprise_id || event.enterprise_id,
                                        department_id:
                                            base.department_id || event.department_id
                                    };

                                    if (
                                        mobileStopOrderData.enterprise_id &&
                                        mobileStopOrderData.department_id
                                    ) {
                                        mobile_stop_stats =
                                            await sendMobileStaffStopAlert(
                                                connection,
                                                mobileStopOrderData
                                            );
                                    } else {
                                        console.warn(
                                            'Skipping mobile stop: missing enterprise_id or department_id',
                                            mobileStopOrderData.enterprise_id,
                                            mobileStopOrderData.department_id
                                        );
                                    }


                                    /* ================= WEBSOCKET ================= */

                                    if (
                                        event.enterprise_id
                                    ) {

                                        await broadcastWsEvent(
                                            event.enterprise_id,
                                            {

                                                type:
                                                    'FOOD_ORDER_STATUS',

                                                order_number:
                                                    base.order_number,

                                                order_id:
                                                    String(
                                                        base.summary_id || ''
                                                    ),

                                                device_id:
                                                    String(
                                                        base.device_id || ''
                                                    ),

                                                device_name:
                                                    base.device_name,

                                                guest_id:
                                                    String(
                                                        base.guest_id || ''
                                                    ),

                                                order_status:
                                                    'accepted',

                                                status:
                                                    'Accepted',

                                                eta_minutes:
                                                    String(
                                                        base.total_eta_minutes || 0
                                                    ),

                                                eta_time:
                                                    String(
                                                        base.eta_time || ''
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

                                            kitchen_accepted_at:
                                                base.kitchen_accepted_at,

                                            accepted_user_id:
                                                base.accepted_user_id,

                                            eta_time:
                                                base.eta_time,

                                            rush_hour:
                                                base.rush_hour,

                                            completion_minutes:
                                                base.completion_minutes,

                                            total_eta_minutes:
                                                base.total_eta_minutes,

                                            notification_stats
                                                ,

                                            mobile_stop_stats
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
