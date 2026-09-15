'use strict';

import mysql from 'mysql';
import fs from 'fs';
import admin from 'firebase-admin';
import path from 'path';
import { fileURLToPath } from 'url';
import { getMessaging } from 'firebase-admin/messaging';


/* ============================================================
   WEBSOCKET BROADCAST
   ============================================================ */

const WS_API_URL =
    "https://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production";


const broadcastWsEvent = async (enterpriseId, payload) => {

    try {

        const controller = new AbortController();

        const timeout = setTimeout(
            () => controller.abort(),
            2000
        );

        const resp = await fetch(
            `${WS_API_URL}/@connections`,
            {
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
            }
        );

        clearTimeout(timeout);

        console.log(
            'WS broadcast status:',
            resp.status
        );

    } catch (e) {

        console.warn(
            'WS broadcast failed:',
            e.message
        );

    }

};


/* ============================================================
   PATH
   ============================================================ */

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);


/* ============================================================
   FIREBASE
   ============================================================ */

let firebaseInitialized = false;


const initializeFirebase = () => {

    if (firebaseInitialized) {
        return;
    }

    const serviceAccountPath =
        path.join(
            __dirname,
            'firebase-key.json'
        );


    if (!fs.existsSync(serviceAccountPath)) {

        console.warn(
            '⚠️ Firebase key not found, notifications disabled'
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


        firebaseInitialized = true;

        console.log(
            '✅ Firebase initialized'
        );

    } catch (err) {

        console.error(
            '❌ Firebase init error:',
            err
        );

    }

};


/* ============================================================
   SEND FOOD ORDER NOTIFICATION
   ============================================================ */

const sendOrderNotification = async (
    connection,
    orderData
) => {

    try {

        initializeFirebase();


        if (!firebaseInitialized) {

            return {
                notificationStats: {
                    sent: 0,
                    failed: 0,
                    totalUsers: 0,
                    users: []
                }
            };

        }


        const messaging = getMessaging();


        /*
         * Users are returned directly by
         * add_order_request_tv procedure.
         *
         * The procedure filters:
         *
         * user_role_dept_mapping
         * users
         * user_fcm_tokens
         *
         * and returns all active Mobile Staff.
         */

        const users =
            orderData.users || [];


        /*
         * Only users having a valid FCM token.
         * Exclude web_pwa_client_token.
         */
        const validUsers =
            users.filter(
                u =>
                    u.token_app &&
                    u.token_app.trim() !== '' &&
                    u.token_app.trim() !== 'web_pwa_client_token'
            );


        if (!validUsers.length) {

            console.log(
                'No valid FCM users returned by procedure'
            );

            return {
                notificationStats: {
                    sent: 0,
                    failed: 0,
                    totalUsers: 0,
                    users: []
                }
            };

        }


        /*
         * Firebase multicast supports maximum
         * 500 tokens per request.
         */
        const tokens =
            validUsers
                .map(u => u.token_app)
                .slice(0, 500);


        /* ========================================================
           FIREBASE PAYLOAD
           ======================================================== */

        const payload = {

            tokens,

            data: {

                type: 'NEW_FOOD_ORDER',

                title:
                    `🍽️ New Order - ${orderData.department_name}`,

                body:
                    `Order #${orderData.order_number} from ${orderData.device_name}`,

                order_number:
                    String(orderData.order_number || ''),

                device_name:
                    String(orderData.device_name || ''),

                food_items:
                    String(orderData.food_items || ''),

                department_id:
                    String(orderData.department_id || '')

            },


            android: {
                priority: 'high'
            }

        };


        /* ========================================================
           SEND FIREBASE NOTIFICATION
           ======================================================== */

        const response =
            await messaging.sendEachForMulticast(
                payload
            );


        /* ========================================================
           NOTIFICATION RESULT
           ======================================================== */

        const usersWithStatus =
            validUsers.map(
                (u, i) => ({

                    user_id:
                        u.user_id,

                    username:
                        u.username,

                    email:
                        u.email,

                    token_app:
                        u.token_app.length > 20
                            ? u.token_app.substring(0, 20) + '...'
                            : u.token_app,

                    success:
                        response.responses[i]?.success || false,

                    error:
                        response.responses[i]?.error?.message || null,

                    sent:
                        response.responses[i]?.success || false

                })
            );


        return {

            notificationStats: {

                sent:
                    response.successCount,

                failed:
                    response.failureCount,

                totalUsers:
                    validUsers.length,

                users:
                    usersWithStatus

            }

        };


    } catch (err) {

        console.error(
            '❌ Notification error:',
            err
        );


        return {

            notificationStats: {

                sent: 0,

                failed: 0,

                totalUsers: 0,

                users: []

            }

        };

    }

};


/* ============================================================
   RESPONSE FORMATTER
   ============================================================ */

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


/* ============================================================
   MAIN HANDLER
   ============================================================ */

export const handler = (
    event,
    context,
    callback
) => {

    context.callbackWaitsForEmptyEventLoop = false;


    /* ==========================================================
       STAGE VALIDATION
       ========================================================== */

    if (!event.stage) {

        return callback(
            null,
            formatResult(
                'E',
                'Missing stage parameter'
            )
        );

    }


    /* ==========================================================
       DATABASE CONFIG
       ========================================================== */

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


        /* ======================================================
           CREATE MYSQL POOL
           ====================================================== */

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


                /* ==================================================
                   SEND REQUEST TO PROCEDURE
                   ================================================== */

                const jsonRequest =
                    JSON.stringify(event);


                connection.query(

                    `
                    CALL ScreenSync.add_order_request_tv(
                        ?,
                        @p_out_mssg_flg,
                        @p_out_mssg
                    )
                    `,

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


                        /* ==========================================
                           GET PROCEDURE STATUS
                           ========================================== */

                        connection.query(

                            `
                            SELECT
                                @p_out_mssg_flg AS flag,
                                @p_out_mssg AS message
                            `,

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


                                /* ==================================
                                   PROCEDURE RESPONSE
                                   ================================== */

                                const flag =
                                    out[0]?.flag;

                                const message =
                                    out[0]?.message;


                                /*
                                 * IMPORTANT FIX:
                                 *
                                 * The procedure returns:
                                 * results[0] → { status, message }
                                 * results[1] → Staff/FCM user rows
                                 *
                                 * Find the result set that contains
                                 * users with token_app.
                                 */
                                const users = Array.isArray(results)
                                    ? (results.find(
                                        result =>
                                            Array.isArray(result) &&
                                            result.length > 0 &&
                                            result[0] &&
                                            Object.prototype.hasOwnProperty.call(result[0], 'token_app')
                                      ) || [])
                                    : [];

                                const base =
                                    users[0] || {};


                                /* ==================================
                                   DEFAULT NOTIFICATION STATS
                                   ================================== */

                                let notification_stats = {

                                    sent: 0,

                                    failed: 0,

                                    totalUsers: 0,

                                    users: []

                                };


                                /* ==================================
                                   SEND PUSH NOTIFICATION
                                   ================================== */

                                if (
                                    flag === 'S' &&
                                    users.length > 0
                                ) {

                                    const notif =
                                        await sendOrderNotification(

                                            connection,

                                            {

                                                users,

                                                order_number:
                                                    base.order_number,

                                                device_name:
                                                    base.device_name,

                                                food_items:
                                                    base.food_items,

                                                department_name:
                                                    base.department_name,

                                                department_id:
                                                    base.department_id

                                            }

                                        );


                                    notification_stats =
                                        notif.notificationStats;


                                    /* =================================
                                       WEBSOCKET
                                       ================================= */

                                    if (
                                        base.enterprise_id
                                    ) {

                                        await broadcastWsEvent(

                                            base.enterprise_id,

                                            {

                                                type:
                                                    'NEW_FOOD_ORDER',

                                                order_number:
                                                    base.order_number,

                                                department_id:
                                                    String(
                                                        base.department_id
                                                    ),

                                                device_name:
                                                    base.device_name

                                            }

                                        );

                                    }

                                }


                                /* ==================================
                                   CLOSE DB CONNECTION
                                   ================================== */

                                connection.destroy();


                                /* ==================================
                                   RESPONSE
                                   ================================== */

                                return callback(

                                    null,

                                    formatResult(

                                        flag,

                                        message,

                                        {

                                            order_number:
                                                base.order_number,

                                            device_name:
                                                base.device_name,

                                            device_location:
                                                base.device_location,

                                            food_items:
                                                base.food_items,

                                            total_items:
                                                base.total_items,

                                            enterprise_id:
                                                base.enterprise_id,

                                            department_id:
                                                base.department_id,

                                            department_name:
                                                base.department_name,

                                            notification_stats

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
