'use strict';

import mysql from 'mysql';
import fs from 'fs';
import admin from 'firebase-admin';
import path from 'path';
import { fileURLToPath } from 'url';
import { getMessaging } from 'firebase-admin/messaging';


/* =========================================================
   WEBSOCKET
========================================================= */

const WS_API_URL =
    "https://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production";


const broadcastWsEvent = async (enterpriseId, payload) => {

    try {

        const controller = new AbortController();

        const timeout =
            setTimeout(() => controller.abort(), 2000);

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


/* =========================================================
   FIREBASE INITIALIZATION
========================================================= */

const __filename =
    fileURLToPath(import.meta.url);

const __dirname =
    path.dirname(__filename);


let firebaseInitialized = false;


const initializeFirebase = () => {

    if (firebaseInitialized)
        return;


    const serviceAccountPath =
        path.join(
            __dirname,
            'firebase-key.json'
        );


    if (!fs.existsSync(serviceAccountPath)) {

        console.warn(
            'Firebase key not found, notifications disabled'
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
            'Firebase initialized'
        );

    } catch (err) {

        console.error(
            'Firebase initialization error:',
            err
        );
    }
};


/* =========================================================
   SEND REASSIGN NOTIFICATION
========================================================= */

const sendReassignNotification =
    async (userData) => {

    try {

        initializeFirebase();


        if (!firebaseInitialized) {

            return {
                sent: 0,
                failed: 0,
                totalUsers: 0,
                users: []
            };
        }


        if (!userData?.token_app?.trim()) {

            console.log(
                'No valid FCM token for reassigned user'
            );

            return {
                sent: 0,
                failed: 0,
                totalUsers: 0,
                users: []
            };
        }


        const messaging =
            getMessaging();


        const title =
            '🔄 Task Assigned to You';


        const body =
            `Service request #${userData.service_request_id} has been assigned to you`;


        const message = {

            token:
                userData.token_app,

            data: {

                type:
                    'TASK_REASSIGNED',

                title:
                    title,

                body:
                    body,

                service_request_id:
                    String(
                        userData.service_request_id || ''
                    ),

                enterprise_id:
                    String(
                        userData.enterprise_id || ''
                    ),

                department_id:
                    String(
                        userData.department_id || ''
                    ),

                department_name:
                    String(
                        userData.department_name || ''
                    ),

                department_type:
                    String(
                        userData.department_type || ''
                    ),

                assigned_by:
                    String(
                        userData.assigned_by || ''
                    ),

                assigned_to:
                    String(
                        userData.assigned_to || ''
                    ),

                room_id:
                    String(
                        userData.room_id || ''
                    ),

                category:
                    String(
                        userData.category || ''
                    ),

                service_order_id:
                    String(
                        userData.service_order_id || ''
                    ),

                service_order_item_id:
                    String(
                        userData.service_order_item_id || ''
                    ),

                is_from_order:
                    String(
                        userData.is_from_order || 0
                    )
            },

            android: {
                priority: 'high'
            }
        };


        console.log(
            'Sending reassignment notification to user:',
            userData.user_id
        );


        const response =
            await messaging.send(message);


        console.log(
            'Reassignment notification sent:',
            response
        );


        return {

            sent: 1,

            failed: 0,

            totalUsers: 1,

            users: [
                {
                    user_id:
                        userData.user_id,

                    username:
                        userData.username,

                    email:
                        userData.email,

                    token_app:
                        userData.token_app
                            ? userData.token_app.substring(0, 20) + '...'
                            : null,

                    enterprise_id:
                        userData.enterprise_id,

                    department_id:
                        userData.department_id,

                    department_name:
                        userData.department_name,

                    success: true,

                    error: null,

                    sent: true
                }
            ]
        };


    } catch (err) {

        console.error(
            'Reassign notification error:',
            err
        );


        return {

            sent: 0,

            failed: 1,

            totalUsers: 1,

            users: [
                {
                    user_id:
                        userData?.user_id,

                    username:
                        userData?.username,

                    success: false,

                    error:
                        err.message,

                    sent: false
                }
            ]
        };
    }
};


/* =========================================================
   RESPONSE FORMAT
========================================================= */

const formatResult =
    (status, message, data = {}) => ({

        RESULT: [
            {
                status,
                message,
                ...data
            }
        ]

    });


/* =========================================================
   MAIN HANDLER
========================================================= */

export const handler =
    (event, context, callback) => {

    context.callbackWaitsForEmptyEventLoop =
        false;


    /* -----------------------------------------------------
       VALIDATE STAGE
    ----------------------------------------------------- */

    if (!event.stage) {

        return callback(
            null,
            formatResult(
                'E',
                'Missing stage parameter'
            )
        );
    }


    /* -----------------------------------------------------
       VALIDATE INPUT
    ----------------------------------------------------- */

    if (!event.user_id) {

        return callback(
            null,
            formatResult(
                'E',
                'Missing user_id'
            )
        );
    }


    if (!event.service_request_id) {

        return callback(
            null,
            formatResult(
                'E',
                'Missing service_request_id'
            )
        );
    }


    if (!event.reassign_to) {

        return callback(
            null,
            formatResult(
                'E',
                'Missing reassign_to'
            )
        );
    }


    /* -----------------------------------------------------
       DATABASE CONFIG
    ----------------------------------------------------- */

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


                /* =================================================
                   CALL REASSIGN PROCEDURE
                ================================================= */

                connection.query(

                    `CALL ScreenSync.reassign_service_mobile1(
                        ?,
                        @p_out_mssg_flg,
                        @p_out_mssg
                    )`,

                    [jsonRequest],

                    (err, results) => {


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


                        /* =========================================
                           GET OUTPUT PARAMETERS
                        ========================================= */

                        connection.query(

                            `SELECT
                                @p_out_mssg_flg AS flag,
                                @p_out_mssg AS message`,

                            async (err2, out) => {


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


                                console.log(
                                    'Procedure flag:',
                                    flag
                                );


                                console.log(
                                    'Procedure message:',
                                    message
                                );


                                console.log(
                                    'Procedure results:',
                                    JSON.stringify(results)
                                );


                                /* =================================
                                   DEFAULT NOTIFICATION STATS
                                ================================= */

                                let notification_stats = {

                                    sent: 0,

                                    failed: 0,

                                    totalUsers: 0,

                                    users: []
                                };


                                let notificationUser =
                                    null;


                                /* =================================
                                   FIND RESULT SET CONTAINING USER
                                ================================= */

                                if (
                                    flag === 'S' &&
                                    Array.isArray(results)
                                ) {

                                    for (
                                        const resultSet
                                        of results
                                    ) {

                                        if (
                                            Array.isArray(resultSet) &&
                                            resultSet.length > 0 &&
                                            resultSet[0]?.token_app
                                        ) {

                                            notificationUser =
                                                resultSet[0];

                                            break;
                                        }
                                    }
                                }


                                /* =================================
                                   SEND PUSH NOTIFICATION
                                ================================= */

                                if (
                                    flag === 'S' &&
                                    notificationUser
                                ) {

                                    console.log(
                                        'Reassigned user:',
                                        notificationUser.user_id
                                    );


                                    notification_stats =
                                        await sendReassignNotification(
                                            notificationUser
                                        );


                                    /* =============================
                                       WEBSOCKET UPDATE
                                    ============================= */

                                    if (
                                        notificationUser.enterprise_id
                                    ) {

                                        await broadcastWsEvent(

                                            notificationUser.enterprise_id,

                                            {
                                                type:
                                                    'TASK_REASSIGNED',

                                                service_request_id:
                                                    String(
                                                        notificationUser.service_request_id
                                                    ),

                                                department_id:
                                                    String(
                                                        notificationUser.department_id
                                                    ),

                                                assigned_by:
                                                    String(
                                                        notificationUser.assigned_by
                                                    ),

                                                assigned_to:
                                                    String(
                                                        notificationUser.assigned_to
                                                    )
                                            }
                                        );
                                    }
                                }


                                connection.destroy();


                                /* =================================
                                   FINAL RESPONSE
                                ================================= */

                                return callback(

                                    null,

                                    formatResult(
                                        flag,
                                        message,
                                        {
                                            service_request_id:
                                                event.service_request_id,

                                            assigned_by:
                                                event.user_id,

                                            assigned_to:
                                                event.reassign_to,

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
