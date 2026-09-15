// lib/models/kot_ticket_model.dart

class KOTItem {
  final String name;
  final int quantity;
  final bool isVeg;
  final String? instructions;
  final double price;
  final double totalPrice;

  KOTItem({
    required this.name,
    required this.quantity,
    this.isVeg = false,
    this.instructions,
    this.price = 0.0,
    this.totalPrice = 0.0,
  });

  factory KOTItem.fromMap(Map<String, dynamic> map) {
    final rawQty = map['qty'] ?? map['quantity'] ?? '1';
    final qtyInt = (rawQty is int) ? rawQty : int.tryParse(rawQty.toString()) ?? 1;

    final isVegVal = map['isVeg'] == true ||
        map['isVeg'] == 1 ||
        map['is_veg'] == 1 ||
        map['is_veg'] == true ||
        map['is_veg'] == '1';

    final nameStr = (map['name'] ?? map['foodItem'] ?? map['food_item'] ?? map['item_name'] ?? map['title'] ?? 'Food Item').toString();
    final instrStr = map['instructions']?.toString() ?? map['cookingInstructions']?.toString() ?? map['cooking_instructions']?.toString();

    final rawPrice = map['price'] ?? map['food_price'] ?? map['item_price'] ?? map['amount'];
    final priceVal = (rawPrice is num) ? rawPrice.toDouble() : (double.tryParse(rawPrice?.toString() ?? '') ?? 0.0);

    final rawTotal = map['totalPrice'] ?? map['total_price'] ?? map['total_amount'];
    final totalVal = (rawTotal is num) ? rawTotal.toDouble() : (double.tryParse(rawTotal?.toString() ?? '') ?? (priceVal * qtyInt));

    return KOTItem(
      name: nameStr,
      quantity: qtyInt,
      isVeg: isVegVal,
      instructions: (instrStr != null && instrStr.trim().isNotEmpty) ? instrStr.trim() : null,
      price: priceVal,
      totalPrice: totalVal,
    );
  }
}

class KOTTicketModel {
  final String orderNumber;
  final String roomNumber;
  final String? guestName;
  final DateTime orderTime;
  final List<KOTItem> items;
  final String? cookingInstructions;
  final String orderStatus;
  final String? stewardName;
  final int? orderRequestId;
  final double totalOrderPrice;

  KOTTicketModel({
    required this.orderNumber,
    required this.roomNumber,
    this.guestName,
    required this.orderTime,
    required this.items,
    this.cookingInstructions,
    required this.orderStatus,
    this.stewardName,
    this.orderRequestId,
    this.totalOrderPrice = 0.0,
  });

  factory KOTTicketModel.fromFoodOrder(Map<String, dynamic> order) {
    final raw = (order['raw'] is Map) ? Map<String, dynamic>.from(order['raw']) : <String, dynamic>{};

    final orderNum = (order['orderNumber'] ?? order['orderNo'] ?? raw['order_number'] ?? 'ORD-${order['orderRequestId'] ?? raw['order_request_id'] ?? '001'}').toString();
    final roomNum = (order['roomNumber'] ?? order['room'] ?? raw['room_number'] ?? raw['room_id'] ?? '101').toString();

    String? guest = (order['guestName'] ?? order['guest'] ?? raw['guest_name'])?.toString();
    if (guest == 'null' || guest == null || guest.trim().isEmpty) {
      guest = null;
    }

    DateTime timeParsed;
    try {
      final rawTime = order['createdAt'] ?? raw['order_time'] ?? order['orderTime'] ?? raw['created_at'];
      if (rawTime is DateTime) {
        timeParsed = rawTime;
      } else if (rawTime != null && rawTime.toString().isNotEmpty) {
        timeParsed = DateTime.tryParse(rawTime.toString()) ?? DateTime.now();
      } else {
        timeParsed = DateTime.now();
      }
    } catch (_) {
      timeParsed = DateTime.now();
    }

    final itemsList = <KOTItem>[];
    if (order['items'] is List && (order['items'] as List).isNotEmpty) {
      for (final itemMap in (order['items'] as List)) {
        if (itemMap is Map<String, dynamic>) {
          itemsList.add(KOTItem.fromMap(itemMap));
        }
      }
    } else {
      final itemMap = <String, dynamic>{
        ...raw,
        ...order,
      };
      itemsList.add(KOTItem.fromMap(itemMap));
    }

    String? instructionsCombined = order['cookingInstructions']?.toString() ??
        raw['cooking_instructions']?.toString() ??
        order['instructions']?.toString();

    if (instructionsCombined == null || instructionsCombined.trim().isEmpty) {
      final instructionsFromItems = itemsList
          .map((i) => i.instructions?.trim() ?? '')
          .where((i) => i.isNotEmpty)
          .toSet()
          .join(', ');
      if (instructionsFromItems.isNotEmpty) {
        instructionsCombined = instructionsFromItems;
      }
    }

    final steward = (order['stewardName'] ?? order['assignedTo'] ?? raw['assigned_to_name'])?.toString();
    final requestId = (order['orderRequestId'] ?? raw['order_request_id']) as int?;

    final rawTotal = order['totalOrderPrice'] ?? raw['total_order_price'] ?? raw['total_amount'] ?? raw['grand_total'] ?? raw['total_price'] ?? raw['amount'];
    double totalOrder = (rawTotal is num) ? rawTotal.toDouble() : (double.tryParse(rawTotal?.toString() ?? '') ?? 0.0);
    if (itemsList.isNotEmpty) {
      final itemsSum = itemsList.fold<double>(0.0, (sum, i) => sum + (i.totalPrice > 0 ? i.totalPrice : (i.price * i.quantity)));
      if (itemsSum > 0 && (itemsList.length > 1 || itemsSum > totalOrder || totalOrder <= 0)) {
        totalOrder = itemsSum;
      }
    }

    return KOTTicketModel(
      orderNumber: orderNum,
      roomNumber: roomNum,
      guestName: guest,
      orderTime: timeParsed,
      items: itemsList,
      cookingInstructions: instructionsCombined,
      orderStatus: (order['status'] ?? raw['order_status'] ?? 'Pending').toString(),
      stewardName: steward,
      orderRequestId: requestId,
      totalOrderPrice: totalOrder,
    );
  }
}
