import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/login_service.dart';
import '../utils/app_colors.dart';
import 'reset_password_page.dart';

class OtpVerifyPage extends StatefulWidget {
  final String mobile;

  const OtpVerifyPage({super.key, required this.mobile});

  @override
  State<OtpVerifyPage> createState() => _OtpVerifyPageState();
}

class _OtpVerifyPageState extends State<OtpVerifyPage> with TickerProviderStateMixin {
  final List<TextEditingController> _controllers = List.generate(4, (_) => TextEditingController()); // 4 digits
  final List<FocusNode> _focusNodes = List.generate(4, (_) => FocusNode());

  bool _isLoading = false;
  bool _isResending = false;
  int _resendCountdown = 30;
  Timer? _timer;

  AnimationController? _successAnimationController;

  String _generatedOtp = ""; // store generated OTP

  @override
  void initState() {
    super.initState();
    _startResendTimer();

    _successAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _focusNodes[0].requestFocus();
    _sendOtp();
  }

  @override
  void dispose() {
    for (var c in _controllers) c.dispose();
    for (var f in _focusNodes) f.dispose();
    _timer?.cancel();
    _successAnimationController?.dispose();
    super.dispose();
  }

  String get _enteredOtp => _controllers.map((c) => c.text).join();

  void _startResendTimer() {
    _resendCountdown = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCountdown <= 0) {
        timer.cancel();
      } else {
        setState(() => _resendCountdown--);
      }
    });
  }

  Future<void> _sendOtp() async {
    setState(() => _isResending = true);

    final response = await LoginService().sendOtp(mobile: widget.mobile);

    setState(() => _isResending = false);

    if (!mounted) return;

    if (!response["success"]) {
      _showSnack(response["message"] ?? "Failed to send OTP");
      return;
    }

    _generatedOtp = response['otp'] ?? ""; // Save 4-digit OTP
    _showSnack("OTP sent successfully");
    _startResendTimer();
  }

  Future<void> _verifyOtp() async {
    if (_enteredOtp.length != 4) { // 4 digits
      _showSnack("Enter valid 4-digit OTP");
      return;
    }

    setState(() => _isLoading = true);

    final response = await LoginService().verifyOtp(
      mobile: widget.mobile,
      otp: _enteredOtp,
    );

    setState(() => _isLoading = false);

    if (!response['success']) {
      _showSnack(response['message'] ?? "Invalid OTP");
      return;
    }

    await _successAnimationController!.forward();
    await Future.delayed(const Duration(milliseconds: 600));

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResetPasswordPage(mobile: widget.mobile),
      ),
    );
  }

  Future<void> _resendOtp() async {
    if (_resendCountdown > 0) return;
    await _sendOtp();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.textPrimary,
      ),
    );
  }

  Widget _buildOtpField(int index) {
    return SizedBox(
      width: 50,
      child: TextField(
        controller: _controllers[index],
        focusNode: _focusNodes[index],
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 1,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          counterText: "",
          filled: true,
          fillColor: AppColors.bgLight,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onChanged: (val) {
          if (val.isNotEmpty && index < 3) _focusNodes[index + 1].requestFocus();
          if (val.isEmpty && index > 0) _focusNodes[index - 1].requestFocus();
        },
      ),
    );
  }

  String get _maskedMobile {
    if (widget.mobile.length != 10) return widget.mobile;
    return "${widget.mobile.substring(0, 3)}****${widget.mobile.substring(7)}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text("OTP Verification", style: TextStyle(color: Colors.black)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          reverse: true,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 20),
              Text(
                "Enter the 4-digit OTP sent to $_maskedMobile",
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.black87),
              ),
              const SizedBox(height: 10),

              if (_generatedOtp.isNotEmpty)
                Text(
                  "Generated OTP: $_generatedOtp",
                  style: const TextStyle(color: AppColors.error, fontSize: 16),
                ),

              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(4, (i) => _buildOtpField(i)),
              ),
              const SizedBox(height: 30),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _verifyOtp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    disabledBackgroundColor: Colors.grey.shade400,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          "Verify OTP",
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 18,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: (_resendCountdown == 0 && !_isResending) ? _resendOtp : null,
                child: Text(
                  _isResending
                      ? "Resending..."
                      : (_resendCountdown > 0 ? "Resend OTP in $_resendCountdown s" : "Resend OTP"),
                  style: TextStyle(
                    color: _resendCountdown == 0 ? Colors.blue : Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
