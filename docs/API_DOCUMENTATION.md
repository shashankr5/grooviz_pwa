# ScreenSync Mobile API Documentation

This document describes the REST API contract for the ScreenSync application. All mobile client requests target the AWS API Gateway base URL.

## Global Headers & Settings

- **Base URL**: `https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production`
- **Headers**:
  - `Content-Type`: `application/json`
  - `x-api-key`: `sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc`

---

## 1. Authentication Endpoints

### 1.1 Mobile Login
- **Endpoint**: `/ScreenSync_login_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "username": "staff_user",
  "password": "secure_password",
  "fcm_token": "fcm_push_registration_token",
  "installation_id": "device_uuid_identifier",
  "device_type": "android",
  "stage": "dev"
}
```
- **Response Payload (Success)**:
```json
{
  "success": true,
  "user_id": 42,
  "message": "Login successful"
}
```

### 1.2 Mobile Logout
- **Endpoint**: `/ScreenSync_logout_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "user_id": 42,
  "installation_id": "device_uuid_identifier",
  "stage": "dev"
}
```
- **Response Payload**:
```json
{
  "RESULT": [
    {
      "status": "S",
      "message": "Session terminated successfully"
    }
  ]
}
```

### 1.3 Send OTP
- **Endpoint**: `/ScreenSync_send_otp_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "email": "user@hotel.com",
  "stage": "dev"
}
```

### 1.4 Verify OTP
- **Endpoint**: `/ScreenSync_verify_otp_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "email": "user@hotel.com",
  "otp": "123456",
  "stage": "dev"
}
```

---

## 2. Profile & Staff Management

### 2.1 Get User Profile
- **Endpoint**: `/ScreenSync_get_profile_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "user_id": 42,
  "stage": "dev"
}
```
- **Response Payload**:
```json
{
  "success": true,
  "user_id": 42,
  "full_name": "John Doe",
  "role_name": "Supervisor",
  "role_id": 5,
  "departments": ["Front Office", "Housekeeping"]
}
```

---

## 3. Tasks & Service Requests

### 3.1 Get Active Tasks
- **Endpoint**: `/ScreenSync_get_tasks_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "user_id": 42,
  "departments": ["Front Office"],
  "stage": "dev"
}
```

### 3.2 Accept Service Task
- **Endpoint**: `/ScreenSync_task_accept_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "task_id": 101,
  "user_id": 42,
  "stage": "dev"
}
```

### 3.3 Close Service Request
- **Endpoint**: `/ScreenSync_close_service_request_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "task_id": 101,
  "user_id": 42,
  "stage": "dev"
}
```

---

## 4. Food Orders

### 4.1 Delivery Management (Unified service requests)
- **List**: `/ScreenSync_get_all_services_mobile1`
- **Accept**: `/ScreenSync_accept_service_request_mobile1`
- **Complete delivery**: `/ScreenSync_close_service_mobile1`
- Food delivery requests are identified by `food_order_summary_id`. Their
  timestamps and ordered items are returned in the unified service response.

### 4.2 Get Rush Hour Status (F&B)
- **Endpoint**: `/ScreenSync_get_rush_hour_state_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "enterprise_id": 42,
  "stage": "dev"
}
```
- **Response Payload**:
```json
{
  "success": true,
  "rush_hour_active": 1,
  "rush_hour_ends_at": "2026-05-23 14:30:00",
  "rush_hour_extra_min": 15
}
```

---

## 5. Checkout

### 5.1 Get Guest Checkout Report
- **Endpoint**: `/ScreenSync_get_guest_checkout_report_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "enterprise_id": 42,
  "checkout_date": "2026-07-23",
  "stage": "dev"
}
```

### 5.2 Get Guest Folio Bill
- **Endpoint**: `/ScreenSync_get_guest_bill_mobile`
- **Method**: `POST`
- **Request Payload**:
```json
{
  "guest_id": 1001,
  "stage": "dev"
}
```
