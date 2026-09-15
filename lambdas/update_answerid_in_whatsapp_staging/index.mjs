'use strict';

import mysql from 'mysql';
import fs from 'fs';
import admin from 'firebase-admin';
import path from 'path';
import { fileURLToPath } from 'url';
import { getMessaging } from 'firebase-admin/messaging';

const WS_API_URL = "https://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production";

const broadcastWsEvent = async (enterpriseId, payload) => {
    try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 2000);
        const resp = await fetch(`${WS_API_URL}/@connections`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
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

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let firebaseInitialized = false;

const initializeFirebase = () => {
    if (firebaseInitialized) {
        return true;
    }

    const serviceAccountPath = path.join(__dirname, 'firebase-key.json');

    if (!fs.existsSync(serviceAccountPath)) {
        console.warn('⚠️ Firebase key not found, notifications will not be sent');
        return false;
    }

    try {
        const serviceAccount = JSON.parse(
            fs.readFileSync(serviceAccountPath, 'utf8')
        );

        if (!admin.apps.length) {
            admin.initializeApp({
                credential: admin.credential.cert(serviceAccount)
            });
        }

        firebaseInitialized = true;
        console.log('✅ Firebase initialized');
        return true;
    } catch (error) {
        console.error('❌ Firebase initialization error:', error.message);
        firebaseInitialized = false;
        return false;
    }
};

const findUserResultSet = (results) => {
    if (!Array.isArray(results)) {
        return [];
    }

    for (const result of results) {
        if (!Array.isArray(result) || result.length === 0) {
            continue;
        }

        const firstRow = result[0];

        if (
            firstRow &&
            Object.prototype.hasOwnProperty.call(firstRow, 'token_app')
        ) {
            return result;
        }
    }

    return [];
};

const sendServiceRequestNotification = async (
    connection,
    instanceId,
    answer,
    customerNumber,
    roomId,
    roomNumber,
    serviceRequestId
) => {
    if (!firebaseInitialized) {
        const initialized = initializeFirebase();

        if (!initialized) {
            return {
                success: false,
                message: 'Firebase not initialized',
                notificationStats: {
                    sent: 0,
                    failed: 0,
                    totalUsers: 0,
                    users: [],
                    enterprise_id: null,
                    department_id: null,
                    service_request_id: serviceRequestId,
                    instance_id: instanceId
                }
            };
        }
    }

    try {
        const messaging = getMessaging();

        return new Promise((resolve) => {
            console.log(
                `Calling get_service_request_notification_mobile1 with service_request_id: ${serviceRequestId}`
            );

            connection.query(
                'CALL `ScreenSync`.`get_service_request_notification_mobile1`(?, @p_out_flag, @p_out_msg)',
                [serviceRequestId],
                async function (err, results) {
                    if (err) {
                        console.error(
                            'Error calling notification procedure:',
                            err
                        );

                        resolve({
                            success: false,
                            message: `Error fetching users: ${err.message}`,
                            notificationStats: {
                                sent: 0,
                                failed: 0,
                                totalUsers: 0,
                                users: [],
                                enterprise_id: null,
                                department_id: null,
                                service_request_id: serviceRequestId,
                                instance_id: instanceId
                            }
                        });
                        return;
                    }

                    console.log(
                        'Notification procedure raw results:',
                        JSON.stringify(results)
                    );

                    connection.query(
                        'SELECT @p_out_flag AS flag, @p_out_msg AS message',
                        async function (flagErr, flagResults) {
                            if (flagErr) {
                                console.error(
                                    'Error getting output parameters:',
                                    flagErr
                                );

                                resolve({
                                    success: false,
                                    message: `Error getting output: ${flagErr.message}`,
                                    notificationStats: {
                                        sent: 0,
                                        failed: 0,
                                        totalUsers: 0,
                                        users: [],
                                        enterprise_id: null,
                                        department_id: null,
                                        service_request_id: serviceRequestId,
                                        instance_id: instanceId
                                    }
                                });
                                return;
                            }

                            const notifyFlag =
                                flagResults && flagResults[0]
                                    ? flagResults[0].flag
                                    : null;

                            const notifyMsg =
                                flagResults && flagResults[0]
                                    ? flagResults[0].message
                                    : null;

                            console.log(
                                `Notification procedure - flag: ${notifyFlag}, message: ${notifyMsg}`
                            );

                            if (notifyFlag !== 'S') {
                                resolve({
                                    success: false,
                                    message:
                                        notifyMsg ||
                                        'Notification procedure failed',
                                    notificationStats: {
                                        sent: 0,
                                        failed: 0,
                                        totalUsers: 0,
                                        users: [],
                                        enterprise_id: null,
                                        department_id: null,
                                        service_request_id: serviceRequestId,
                                        instance_id: instanceId
                                    }
                                });
                                return;
                            }

                            const users = findUserResultSet(results);

                            console.log(
                                `Found ${users.length} Staff rows from notification procedure`
                            );

                            if (users.length === 0) {
                                resolve({
                                    success: false,
                                    message:
                                        'No Staff users with FCM tokens found',
                                    notificationStats: {
                                        sent: 0,
                                        failed: 0,
                                        totalUsers: 0,
                                        users: [],
                                        enterprise_id: null,
                                        department_id: null,
                                        service_request_id: serviceRequestId,
                                        instance_id: instanceId,
                                        procedure_message: notifyMsg
                                    }
                                });
                                return;
                            }

                            const validUsers = users
                                .filter(
                                    user =>
                                        user &&
                                        user.token_app &&
                                        String(user.token_app).trim() !== '' &&
                                        String(user.token_app).trim() !== 'web_pwa_client_token'
                                )
                                .map(user => ({
                                    user_id: user.user_id || null,
                                    username: user.username || 'Unknown',
                                    fcm_token: String(user.token_app).trim(),
                                    enterprise_id:
                                        user.enterprise_id || null,
                                    department_id:
                                        user.department_id || null,
                                    department_name:
                                        user.department_name || null,
                                    department_type:
                                        user.department_type || null,
                                    escalation_enabled:
                                        user.escalation_enabled ?? null,
                                    acceptance_minutes:
                                        user.acceptance_minutes ?? null,
                                    sent: false,
                                    error: null
                                }));

                            console.log(
                                `Found ${validUsers.length} valid FCM users`
                            );

                            if (validUsers.length === 0) {
                                resolve({
                                    success: false,
                                    message: 'No valid FCM tokens found',
                                    notificationStats: {
                                        sent: 0,
                                        failed: 0,
                                        totalUsers: 0,
                                        users: [],
                                        enterprise_id: null,
                                        department_id: null,
                                        service_request_id: serviceRequestId,
                                        instance_id: instanceId
                                    }
                                });
                                return;
                            }

                            const tokenMap = new Map();

                            for (const user of validUsers) {
                                if (!tokenMap.has(user.fcm_token)) {
                                    tokenMap.set(user.fcm_token, user);
                                }
                            }

                            const uniqueUsers = Array.from(
                                tokenMap.values()
                            );

                            const fcmTokens = uniqueUsers
                                .map(user => user.fcm_token)
                                .slice(0, 500);

                            console.log(
                                `Sending notification to ${fcmTokens.length} unique FCM tokens`
                            );

                            try {
                                const payload = {
                                    tokens: fcmTokens,
                                   // notification: {
                                    //    title: '📢 New Service Request',
                                    //    body: `New request from ${customerNumber || 'Guest'}`
                                //    },
                                    data: {
                                        type: 'NEW_SERVICE_REQUEST',
                                        title: '📢 New Service Request',
                                        body: `New request from Room ${roomNumber || 'Guest'}`,
                                        room_id: String(roomId || ''),
                                        room_number: String(roomNumber || ''),
                                        instance_id: String(instanceId || ''),
                                        customer_number: String(customerNumber || ''),
                                        service_request_id: String(serviceRequestId),
                                        message:
                                            String(
                                                answer ||
                                                'New service request created'
                                            ),
                                        priority: 'Normal',
                                        timestamp: new Date().toISOString(),
                                        enterprise_id: String(
                                            uniqueUsers[0]?.enterprise_id || ''
                                        ),
                                        department_id: String(
                                            uniqueUsers[0]?.department_id || ''
                                        )
                                    },
                                    android: {
                                        priority: 'high'
                                    },
                                    apns: {
                                        payload: {
                                            aps: {
                                                sound: 'default',
                                                badge: 1
                                            }
                                        }
                                    }
                                };

                                const response =
                                    await messaging.sendEachForMulticast(
                                        payload
                                    );

                                console.log(
                                    `✅ Notifications sent: ${response.successCount} successful, ${response.failureCount} failed`
                                );

                                const usersWithStatus =
                                    uniqueUsers.map((user, index) => {
                                        const fcmResponse =
                                            response.responses[index];

                                        return {
                                            user_id: user.user_id,
                                            username: user.username,
                                            token_app:
                                                user.fcm_token.substring(0, 20) +
                                                '...',
                                            success:
                                                fcmResponse?.success || false,
                                            error:
                                                fcmResponse?.error?.message ||
                                                null,
                                            enterprise_id:
                                                user.enterprise_id,
                                            department_id:
                                                user.department_id,
                                            department_name:
                                                user.department_name,
                                            department_type:
                                                user.department_type,
                                            escalation_enabled:
                                                user.escalation_enabled,
                                            acceptance_minutes:
                                                user.acceptance_minutes,
                                            sent:
                                                fcmResponse?.success || false
                                        };
                                    });

                                const sentCount =
                                    usersWithStatus.filter(
                                        user => user.success
                                    ).length;

                                const failedCount =
                                    usersWithStatus.filter(
                                        user => !user.success
                                    ).length;

                                if (failedCount > 0) {
                                    usersWithStatus.forEach(user => {
                                        if (!user.success) {
                                            console.error(
                                                `Failed to send to user ${user.username} (ID: ${user.user_id}): ${user.error}`
                                            );
                                        }
                                    });
                                }

                                resolve({
                                    success: sentCount > 0,
                                    message:
                                        `Sent ${sentCount} notifications, ${failedCount} failed`,
                                    notificationStats: {
                                        sent: sentCount,
                                        failed: failedCount,
                                        totalUsers: uniqueUsers.length,
                                        users: usersWithStatus,
                                        enterprise_id:
                                            uniqueUsers[0]?.enterprise_id ||
                                            null,
                                        department_id:
                                            uniqueUsers[0]?.department_id ||
                                            null,
                                        instance_id: instanceId,
                                        customer_number: customerNumber,
                                        service_request_id: serviceRequestId,
                                        answer: answer,
                                        escalation_enabled:
                                            uniqueUsers[0]
                                                ?.escalation_enabled ?? null,
                                        get_service_request_notification_mobile:
                                            {
                                                flag: notifyFlag,
                                                message: notifyMsg,
                                                user_count: users.length,
                                                token_count: uniqueUsers.length
                                            }
                                    }
                                });
                            } catch (sendError) {
                                console.error(
                                    '❌ Error sending notification:',
                                    sendError
                                );

                                resolve({
                                    success: false,
                                    message: sendError.message,
                                    notificationStats: {
                                        sent: 0,
                                        failed: uniqueUsers.length,
                                        totalUsers: uniqueUsers.length,
                                        users: uniqueUsers.map(user => ({
                                            user_id: user.user_id,
                                            username: user.username,
                                            token_app:
                                                user.fcm_token.substring(0, 20) +
                                                '...',
                                            success: false,
                                            error: sendError.message,
                                            enterprise_id:
                                                user.enterprise_id,
                                            department_id:
                                                user.department_id,
                                            sent: false
                                        })),
                                        enterprise_id:
                                            uniqueUsers[0]?.enterprise_id ||
                                            null,
                                        department_id:
                                            uniqueUsers[0]?.department_id ||
                                            null,
                                        service_request_id: serviceRequestId,
                                        instance_id: instanceId
                                    }
                                });
                            }
                        }
                    );
                }
            );
        });
    } catch (error) {
        console.error(
            '❌ Notification error:',
            error
        );

        return {
            success: false,
            message: error.message,
            notificationStats: {
                sent: 0,
                failed: 0,
                totalUsers: 0,
                users: [],
                enterprise_id: null,
                department_id: null,
                service_request_id: serviceRequestId,
                instance_id: instanceId
            }
        };
    }
};

export const handler = (
    event,
    context,
    callback
) => {
    context.callbackWaitsForEmptyEventLoop = false;

    const stage = event?.stage || 'dev';

    const configFile =
        stage === 'prod'
            ? '/opt/nodejs/node_modules/dbConfig.json'
            : '/opt/nodejs/node_modules/dbConfig_dev.json';

    try {
        const configData =
            fs.readFileSync(
                configFile,
                'utf-8'
            );

        const dbconfig =
            JSON.parse(configData);

        const pool =
            mysql.createPool({
                host: dbconfig.dbhost,
                user: dbconfig.dbuser,
                password: dbconfig.dbpassword,
                database: dbconfig.dbname
            });

        pool.getConnection(
            function (
                err,
                connection
            ) {
                if (err) {
                    callback(err);
                    return;
                }

                console.log(
                    'Connected to DB: ' +
                    dbconfig.dbname
                );

                console.log(
                    'Incoming event:',
                    JSON.stringify(event)
                );

                const jsonRequest =
                    JSON.stringify(event);

                connection.query(
                    'CALL `ScreenSync`.`UPDATE_ANSWERID_IN_WHATSAPP_STAGING`(?, @p_out_flag, @p_out_msg)',
                    [jsonRequest],
                    async function (
                        error,
                        results
                    ) {
                        if (error) {
                            connection.destroy();
                            callback(error);
                            return;
                        }

                        console.log(
                            'UPDATE_ANSWERID result:',
                            JSON.stringify(results)
                        );

                        const procedureResult =
                            results &&
                            Array.isArray(results[0]) &&
                            results[0][0]
                                ? results[0][0]
                                : null;

                        let finalResponse = {
                            ...(procedureResult || {}),
                            notification_stats: null
                        };

                        try {
                            if (
                                procedureResult &&
                                procedureResult.L_INSTANCE_ID
                            ) {
                                initializeFirebase();

                                const instanceId =
                                    procedureResult.L_INSTANCE_ID;

                                const answer =
                                    procedureResult.answer ||
                                    'New service request created';

                                const customerNumber =
                                    procedureResult.customer_number;
                                
                                const roomId =
                                    procedureResult.room_id;
                                
                                const roomNumber =
                                    procedureResult.room_number;    

                                /*
                                 * IMPORTANT:
                                 * Use the actual service_request_id
                                 * returned by UPDATE_ANSWERID...
                                 *
                                 * Do NOT use the incoming request_id
                                 * because that is whatsapp_staging_id.
                                 */
                                const serviceRequestId =
                                    procedureResult.service_request_id;

                                console.log(
                                    'Created service_request_id:',
                                    serviceRequestId
                                );

                                if (
                                    serviceRequestId !== null &&
                                    serviceRequestId !== undefined &&
                                    Number(serviceRequestId) > 0
                                ) {
                                    const numericServiceRequestId =
                                        Number(serviceRequestId);

                                    const notificationResult =
                                        await sendServiceRequestNotification(
                                            connection,
                                            instanceId,
                                            answer,
                                            customerNumber,
                                            roomId,
                                            roomNumber,
                                            numericServiceRequestId
                                        );

                                    finalResponse.notification_stats =
                                        notificationResult.notificationStats;

                                    console.log(
                                        '📊 Notification Statistics Summary:'
                                    );

                                    console.log(
                                        `   Service Request ID: ${numericServiceRequestId}`
                                    );

                                    console.log(
                                        `   Total Users: ${notificationResult.notificationStats.totalUsers}`
                                    );

                                    console.log(
                                        `   Successfully Sent: ${notificationResult.notificationStats.sent}`
                                    );

                                    console.log(
                                        `   Failed: ${notificationResult.notificationStats.failed}`
                                    );

                                    console.log(
                                        `   Enterprise ID: ${notificationResult.notificationStats.enterprise_id}`
                                    );

                                    console.log(
                                        `   Department ID: ${notificationResult.notificationStats.department_id}`
                                    );

                                    if (
                                        notificationResult
                                            .notificationStats
                                            .users &&
                                        notificationResult
                                            .notificationStats
                                            .users.length > 0
                                    ) {
                                        console.log(
                                            '👥 Users who received notifications:'
                                        );

                                        notificationResult
                                            .notificationStats
                                            .users
                                            .forEach(
                                                (
                                                    user,
                                                    index
                                                ) => {
                                                    console.log(
                                                        `   ${
                                                            index + 1
                                                        }. ${
                                                            user.username
                                                        } (ID: ${
                                                            user.user_id
                                                        }) - ${
                                                            user.success
                                                                ? '✅ Sent'
                                                                : '❌ Failed: ' +
                                                                  user.error
                                                        }`
                                                    );
                                                }
                                            );
                                    }
                                } else {
                                    console.error(
                                        '❌ UPDATE_ANSWERID did not return a valid service_request_id'
                                    );

                                    finalResponse.notification_stats = {
                                        sent: 0,
                                        failed: 0,
                                        totalUsers: 0,
                                        users: [],
                                        enterprise_id: null,
                                        department_id: null,
                                        service_request_id:
                                            serviceRequestId || null,
                                        instance_id: instanceId,
                                        error:
                                            'service_request_id was not returned by UPDATE_ANSWERID_IN_WHATSAPP_STAGING'
                                    };
                                }
                            }

                            callback(
                                null,
                                finalResponse
                            );

                            console.log(
                                'Final response:',
                                JSON.stringify(finalResponse)
                            );
                        } catch (
                            notifError
                        ) {
                            console.error(
                                'Error in notification process:',
                                notifError
                            );

                            callback(
                                null,
                                finalResponse
                            );
                        } finally {
                            connection.destroy();
                        }
                    }
                );
            }
        );
    } catch (error) {
        callback(
            `Error reading config file: ${error.message}`
        );
    }
};