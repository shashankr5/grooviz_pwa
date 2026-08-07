import 'package:flutter/material.dart';
import 'food_orders_page.dart';

/// DeliveryPage acts as a dedicated wrapper for the Food / Room Service
/// Delivery management view, enabling clean deep-link notification routing.
class DeliveryPage extends StatelessWidget {
  const DeliveryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const FoodOrdersPage();
  }
}
