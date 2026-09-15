'use strict';

import mysql from 'mysql';
import fs from 'fs';
import admin from 'firebase-admin';
import path from 'path';
import { fileURLToPath } from 'url';
import { getMessaging } from 'firebase-admin/messaging';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

let firebaseInitialized = false;

// ─────────────────────────────────────────────
// FIREBASE INIT
// ─────────────────────────────────────────────
const initializeFirebase = () => {
    if (firebaseInitialized) return;

    const keyPath = path.join(__dirname, 'firebase-key.json');
    if (!fs.existsSync(keyPath)) {
        console.warn('⚠️  Firebase key not found – notifications disabled');
        return;
    }
    try {
        const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
        admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
        firebaseInitialized = true;
        console.log('✅ Firebase initialized');
    } catch (err) {
        console.error('❌ Firebase init error:', err);
    }
};

// ─────────────────────────────────────────────
// SEND TV SERVICE NOTIFICATION
// ─────────────────────────────────────────────
const sendTvServiceNotification = async (orderData) => {
    if (!firebaseInitialized) {
        return {
            success: false,
            message: 'Firebase not initialized',
            notificationStats: { sent: 0, failed: 0, totalUsers: 0, users: [] }
        };
    }

    const {
        enterprise_id:   enterpriseId,
        department_id:   departmentId,
        department_type: departmentType = 'service',
        order_flow:      serviceOrderFlow = 'direct',
        order_number:    orderNumber,
        guest_name:      guestName,
        booking_summary: bookingSummary,
        order_id:        orderId,
        notification_users: notificationUsers = []
    } = orderData;

    // ─────────────────────────────────────────────
    // FIX: Parse notification_users if it's a string
    // ─────────────────────────────────────────────
    let users = notificationUsers;

    if (typeof notificationUsers === 'string') {
        try {
            users = JSON.parse(notificationUsers);
        } catch (e) {
            console.warn('⚠️ Failed to parse notification_users:', e);
            users = [];
        }
    }

    if (!Array.isArray(users)) {
        users = [];
    }

    console.log(`📤 TV notification – Order: ${orderNumber}, Flow: ${serviceOrderFlow}, Users: ${users.length}`);

    if (users.length === 0) {
        console.log('ℹ️  No users to notify from procedure');
        return {
            success: true,
            message: 'No users to notify',
            notificationStats: { sent: 0, failed: 0, totalUsers: 0, users: [] }
        };
    }

    // Filter valid tokens
    const validUsers = users
        .filter(u => u.token_app && u.token_app.trim() !== '')
        .map(u => ({
            user_id:           u.user_id,
            username:          u.username || 'Unknown',
            fcm_token:         u.token_app.trim(),
            enterprise_id:     u.enterprise_id || enterpriseId,
            department_id:     u.department_id,
            department_name:   u.department_name,
            completion_minutes: u.completion_minutes,
            access_json:       u.access_json
        }));

    console.log(`👥 ${validUsers.length} users with valid FCM tokens`);

    if (validUsers.length === 0) {
        return {
            success: true,
            message: 'No valid FCM tokens found',
            notificationStats: { sent: 0, failed: 0, totalUsers: 0, users: [] }
        };
    }

    // Build notification content
    const notificationType = 'SERVICE_ORDER';
    const title = '📢 New Service Order';
    const body = `Order #${orderNumber}: ${bookingSummary || 'New service order'}`;

    const payload = {
        tokens: validUsers.map(u => u.fcm_token).slice(0, 500),
        data: {
            type:            notificationType,
            title,
            body,
            order_number:    orderNumber    || '',
            order_id:        String(orderId || ''),
            guest_name:      guestName      || '',
            booking_summary: bookingSummary || '',
            order_flow:      serviceOrderFlow,
            department_type: departmentType,
            department_id:   String(departmentId || ''),
            enterprise_id:   String(enterpriseId || ''),
            timestamp:       new Date().toISOString()
        },
        android: { priority: 'high' },
        apns:    { payload: { aps: { sound: 'default', badge: 1 } } }
    };

    try {
        const response = await getMessaging().sendEachForMulticast(payload);
        console.log(`✅ Sent: ${response.successCount}, Failed: ${response.failureCount}`);

        const usersWithStatus = validUsers.map((u, i) => ({
            user_id:           u.user_id,
            username:          u.username,
            token_app:         u.fcm_token.substring(0, 20) + '...',
            enterprise_id:     u.enterprise_id,
            department_id:     u.department_id,
            department_name:   u.department_name,
            completion_minutes: u.completion_minutes,
            success:           response.responses[i]?.success ?? false,
            error:             response.responses[i]?.error?.message ?? null
        }));

        usersWithStatus
            .filter(u => !u.success)
            .forEach(u => console.log(`   ❌ ${u.username} (${u.user_id}): ${u.error}`));

        return {
            success: true,
            message: `Sent ${response.successCount}, failed ${response.failureCount}`,
            notificationStats: {
                sent:              response.successCount,
                failed:            response.failureCount,
                totalUsers:        validUsers.length,
                users:             usersWithStatus,
                enterprise_id:     enterpriseId,
                department_id:     departmentId,
                department_type:   departmentType,
                notification_type: notificationType,
                order_number:      orderNumber,
                order_flow:        serviceOrderFlow
            }
        };
    } catch (sendErr) {
        console.error('❌ FCM send error:', sendErr);
        return {
            success: false,
            message: sendErr.message,
            notificationStats: {
                sent: 0, failed: validUsers.length,
                totalUsers: validUsers.length,
                users: validUsers.map(u => ({
                    user_id:       u.user_id,
                    username:      u.username,
                    enterprise_id: u.enterprise_id,
                    department_id: u.department_id,
                    success:       false,
                    error:         sendErr.message
                }))
            }
        };
    }
};

// ─────────────────────────────────────────────
// LAMBDA HANDLER
// ─────────────────────────────────────────────
export const handler = (event, context, callback) => {
    context.callbackWaitsForEmptyEventLoop = false;

    const stage      = event.stage || 'dev';
    const configFile = stage === 'prod'
        ? '/opt/nodejs/node_modules/dbConfig.json'
        : '/opt/nodejs/node_modules/dbConfig_dev.json';

    let dbconfig;
    try {
        dbconfig = JSON.parse(fs.readFileSync(configFile, 'utf-8'));
    } catch (err) {
        console.error('❌ Config read error:', err);
        callback(`Error: ${err.message}`);
        return;
    }

    const pool = mysql.createPool({
        host:     dbconfig.dbhost,
        user:     dbconfig.dbuser,
        password: dbconfig.dbpassword,
        database: dbconfig.dbname
    });

    pool.getConnection((err, connection) => {
        if (err) {
            console.error('❌ DB connection error:', err);
            callback(err);
            return;
        }

        console.log('✅ Connected to DB:', dbconfig.dbname);
        console.log('📥 Event:', JSON.stringify(event));

        connection.query(
            'CALL `ScreenSync`.`add_service_booking_tv`(?, @p_out_mssg_flg, @p_out_mssg)',
            [JSON.stringify(event)],
            async (error, results) => {
                if (error) {
                    console.error('❌ Procedure error:', error);
                    connection.destroy();
                    callback(error);
                    return;
                }

                const responseData = {
                    STATUS: results[0] || [],
                    RESULT: results[1] || []
                };

                console.log('📊 STATUS:', JSON.stringify(results[0]));
                console.log('📊 RESULT:', JSON.stringify(results[1]));

                const orderData = results?.[1]?.[0] ?? null;

                if (orderData?.order_id > 0 && orderData?.order_flow === 'direct') {
                    try {
                        initializeFirebase();
                        if (firebaseInitialized) {
                            console.log('📤 Sending notification using procedure result...');
                            const notifResult = await sendTvServiceNotification(orderData);
                            responseData.NOTIFICATION_STATS = notifResult.notificationStats;
                            console.log('📊 Notification stats:', JSON.stringify(notifResult.notificationStats));
                        } else {
                            responseData.NOTIFICATION_STATS = {
                                sent: 0, failed: 0, totalUsers: 0,
                                message: 'Firebase not initialized'
                            };
                        }
                    } catch (notifErr) {
                        console.error('❌ Notification error:', notifErr);
                        responseData.NOTIFICATION_STATS = {
                            sent: 0, failed: 0, totalUsers: 0,
                            message: notifErr.message
                        };
                    }
                } else {
                    responseData.NOTIFICATION_STATS = {
                        sent: 0, failed: 0, totalUsers: 0,
                        message: orderData?.order_id > 0 ? 'Pending flow - no notification sent' : 'No order created'
                    };
                }

                console.log('📤 Final response:', JSON.stringify(responseData));
                connection.destroy();
                callback(null, responseData);
            }
        );
    });
};
