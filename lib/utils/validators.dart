class Validators {
  Validators._();

  /// Validate if field is not empty. Returns error message or null.
  static String? validateRequired(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    return null;
  }

  /// Validate if input is a valid email address.
  static String? validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Email is required';
    }
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Enter a valid email address';
    }
    return null;
  }

  /// Validate if input meets password rules.
  static String? validatePassword(String? value, {int minLength = 6}) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < minLength) {
      return 'Password must be at least $minLength characters';
    }
    return null;
  }

  /// Validate minimum length for a generic field.
  static String? validateMinLength(String? value, int minLength, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    if (value.trim().length < minLength) {
      return '$fieldName must be at least $minLength characters';
    }
    return null;
  }

  /// Validate if input is a valid 10-digit mobile number.
  static String? validateMobileNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Mobile number is required';
    }
    if (value.trim().length != 10) {
      return 'Enter valid 10-digit number';
    }
    return null;
  }

  /// Validate if input is a valid 4-digit OTP.
  static String? validateOtp(String? value) {
    if (value == null || value.trim().length != 4) {
      return 'Enter valid 4-digit OTP';
    }
    return null;
  }

  /// Validate that the confirmation password matches the new password.
  static String? validateConfirmPassword(String? val, String? originalVal) {
    if (val != originalVal) {
      return 'Passwords do not match';
    }
    return null;
  }
}
