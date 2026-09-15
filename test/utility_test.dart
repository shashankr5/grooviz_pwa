import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:com.tekchant.screensyncmobileapp/utils/type_converter.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/date_formatter.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/validators.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/error_handler.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/retry_utils.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/calculation_utils.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/delivery_utils.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/api_error_mapper.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/loading_state.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/app_preferences.dart';
import 'package:com.tekchant.screensyncmobileapp/constants/storage_keys.dart';
import 'package:com.tekchant.screensyncmobileapp/utils/user_session_helper.dart';

enum TestEnum { one, two, three }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TypeConverter Tests', () {
    test('safeToInt converts dynamic inputs properly', () {
      expect(TypeConverter.safeToInt(42), 42);
      expect(TypeConverter.safeToInt(42.8), 42);
      expect(TypeConverter.safeToInt('100'), 100);
      expect(TypeConverter.safeToInt('50.5'), 50);
      expect(TypeConverter.safeToInt(true), 1);
      expect(TypeConverter.safeToInt(null, defaultValue: -1), -1);
      expect(TypeConverter.safeToInt('invalid', defaultValue: 9), 9);
    });

    test('safeToDouble converts dynamic inputs properly', () {
      expect(TypeConverter.safeToDouble(3.14), 3.14);
      expect(TypeConverter.safeToDouble(10), 10.0);
      expect(TypeConverter.safeToDouble('2.71'), 2.71);
      expect(TypeConverter.safeToDouble(true), 1.0);
      expect(TypeConverter.safeToDouble(null, defaultValue: -1.0), -1.0);
      expect(TypeConverter.safeToDouble('invalid', defaultValue: 1.5), 1.5);
    });

    test('safeToNum converts dynamic inputs properly', () {
      expect(TypeConverter.safeToNum(12), 12);
      expect(TypeConverter.safeToNum(12.5), 12.5);
      expect(TypeConverter.safeToNum('50'), 50);
      expect(TypeConverter.safeToNum('invalid', defaultValue: 5), 5);
    });

    test('safeToList parses standard and serialized lists', () {
      expect(TypeConverter.safeToList<int>([1, 2, 3]), [1, 2, 3]);
      expect(TypeConverter.safeToList<String>(['a', 'b']), ['a', 'b']);
      expect(TypeConverter.safeToList<int>('[1,2,3]'), [1, 2, 3]);
      expect(TypeConverter.safeToList<int>(null), <int>[]);
    });

    test('safeToMap parses standard and serialized maps', () {
      expect(TypeConverter.safeToMap({'k': 'v'}), {'k': 'v'});
      expect(TypeConverter.safeToMap('{"key": 10}'), {'key': 10});
      expect(TypeConverter.safeToMap(null), <String, dynamic>{});
    });

    test('safeToEnum retrieves matching enum or returns default', () {
      expect(TypeConverter.safeToEnum('two', TestEnum.values), TestEnum.two);
      expect(TypeConverter.safeToEnum('invalid', TestEnum.values), TestEnum.one);
    });

    test('safeToColor extracts colors from hex strings', () {
      expect(TypeConverter.safeToColor('#FF0000'), const Color(0xFFFF0000));
      expect(TypeConverter.safeToColor('0xFF00FF00'), const Color(0xFF00FF00));
      expect(TypeConverter.safeToColor(0xFF0000FF), const Color(0xFF0000FF));
      expect(TypeConverter.safeToColor(null, defaultColor: Colors.black), Colors.black);
    });

    test('safeToBool parses boolean representations', () {
      expect(TypeConverter.safeToBool(true), true);
      expect(TypeConverter.safeToBool('1'), true);
      expect(TypeConverter.safeToBool('true'), true);
      expect(TypeConverter.safeToBool('yes'), true);
      expect(TypeConverter.safeToBool(false), false);
      expect(TypeConverter.safeToBool('0'), false);
    });
  });

  group('DateFormatter Tests', () {
    test('formatTime parses standard time parts', () {
      expect(DateFormatter.formatTime('2026-05-23 14:30:15'), '14:30');
      expect(DateFormatter.formatTime('14:30:00'), '14:30:00'); // incomplete format
      expect(DateFormatter.formatTime(null), '—');
    });

    test('formatDateTime formats date time properly', () {
      expect(DateFormatter.formatDateTime('2026-05-23 14:30:15'), '23/05/26 · 14:30');
      expect(DateFormatter.formatDateTime(null), '—');
    });

    test('formatDateOnly extracts date parts', () {
      expect(DateFormatter.formatDateOnly('2026-05-23 14:30:15'), '23/05/26');
      expect(DateFormatter.formatDateOnly(null), '—');
    });
  });

  group('Validators Tests', () {
    test('validateRequired works on empty checks', () {
      expect(Validators.validateRequired(null, 'Name'), 'Name is required');
      expect(Validators.validateRequired('', 'Name'), 'Name is required');
      expect(Validators.validateRequired('John', 'Name'), null);
    });

    test('validateEmail checks standard email schemes', () {
      expect(Validators.validateEmail('invalid'), 'Enter a valid email address');
      expect(Validators.validateEmail('test@example.com'), null);
    });

    test('validatePassword checks minimum length', () {
      expect(Validators.validatePassword('123'), 'Password must be at least 6 characters');
      expect(Validators.validatePassword('123456'), null);
    });

    test('validateMobileNumber checks 10 digit constraint', () {
      expect(Validators.validateMobileNumber(null), 'Mobile number is required');
      expect(Validators.validateMobileNumber('123'), 'Enter valid 10-digit number');
      expect(Validators.validateMobileNumber('1234567890'), null);
    });
  });

  group('ErrorHandler & ApiErrorMapper Tests', () {
    test('friendlyMessage translates exception texts', () {
      expect(ErrorHandler.friendlyMessage('SocketException: failed'), contains('Something went wrong'));
      expect(ErrorHandler.friendlyMessage('TimeoutException: tick'), contains('Something went wrong'));
    });

    test('mapStatusCodeToMessage returns standard text', () {
      expect(ApiErrorMapper.mapStatusCodeToMessage(401), contains('Session expired'));
      expect(ApiErrorMapper.mapStatusCodeToMessage(500), contains('server-side error'));
    });

    test('mapResponseToErrorMessage extracts errors from response', () {
      expect(ApiErrorMapper.mapResponseToErrorMessage({'message': 'API Error'}), 'API Error');
      expect(ApiErrorMapper.mapResponseToErrorMessage({
        'RESULT': [{'message': 'Nested Error'}]
      }), 'Nested Error');
    });
  });

  group('RetryUtils Tests', () {
    test('retry executes action on first attempt if successful', () async {
      int calls = 0;
      final res = await RetryUtils.retry(() async {
        calls++;
        return 'success';
      });
      expect(res, 'success');
      expect(calls, 1);
    });

    test('retry executes action multiple times on failures', () async {
      int calls = 0;
      try {
        await RetryUtils.retry(() async {
          calls++;
          throw Exception('Fail');
        }, maxAttempts: 2, delay: const Duration(milliseconds: 1));
      } catch (_) {}
      expect(calls, 2);
    });
  });

  group('CalculationUtils Tests', () {
    test('calculateRate calculates rate to 1 decimal place', () {
      expect(CalculationUtils.calculateRate(5, 10), 50.0);
      expect(CalculationUtils.calculateRate(1, 3), 33.3);
      expect(CalculationUtils.calculateRate(0, 0), 0.0);
    });

    test('sumListValues aggregates item values safely', () {
      final items = [
        {'price': 10},
        {'price': 20.5},
        {'price': null},
      ];
      expect(CalculationUtils.sumListValues(items, 'price'), 30.5);
    });
  });

  group('DeliveryUtils Tests', () {
    test('isDeliveryActive checks non-terminal states', () {
      expect(DeliveryUtils.isDeliveryActive('pending'), true);
      expect(DeliveryUtils.isDeliveryActive('accepted'), true);
      expect(DeliveryUtils.isDeliveryActive('delivered'), false);
      expect(DeliveryUtils.isDeliveryActive('cancelled'), false);
    });
  });

  group('LoadingState Tests', () {
    test('LoadingStateExtension getters return correct values', () {
      const loading = LoadingState.loading;
      const success = LoadingState.success;
      expect(loading.isLoading, true);
      expect(loading.isSuccess, false);
      expect(success.isSuccess, true);
    });
  });

  group('AppPreferences Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'key1': 'val1',
        'key2': 100,
        'preserved_key': 'keep_me',
      });
    });

    test('setString and getString write and retrieve values', () async {
      final success = await AppPreferences.setString('key1', 'new_val');
      expect(success, true);
      expect(await AppPreferences.getString('key1'), 'new_val');
    });

    test('clear wipes data except preserved keys', () async {
      await AppPreferences.clear(preserveKeys: ['preserved_key']);
      expect(await AppPreferences.getString('key1'), null);
      expect(await AppPreferences.getString('preserved_key'), 'keep_me');
    });

    test('clearSession actually logs the user out and clears auth state', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.userId: 42,
        StorageKeys.isLoggedIn: true,
        StorageKeys.installationId: 'inst-123',
      });

      await UserSessionHelper.saveIsLoggedIn(true);
      await UserSessionHelper.clearSession();

      expect(await UserSessionHelper.isLoggedIn(), false);
      expect(await UserSessionHelper.getUserId(), null);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StorageKeys.installationId), 'inst-123');
    });
  });
}
