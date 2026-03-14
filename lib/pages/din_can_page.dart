import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

// ===================== 公共模型/枚举（保持不变） =====================
// 菜品模型
class FoodModel {
  final int id;
  final String name;
  final String category;
  final double price;
  final String? imageUrl;
  final String? description;

  FoodModel({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    this.imageUrl,
    this.description,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'price': price,
    'imageUrl': imageUrl,
    'description': description,
  };

  factory FoodModel.fromJson(Map<String, dynamic> json) => FoodModel(
    id: json['id'],
    name: json['name'],
    category: json['category'],
    price: json['price'].toDouble(),
    imageUrl: json['imageUrl'],
    description: json['description'],
  );
}

// 购物车菜品项
class CartItem {
  final FoodModel food;
  int count;
  bool isSentToKitchen;
  DateTime? sentTime;

  CartItem({
    required this.food,
    this.count = 1,
    this.isSentToKitchen = false,
    this.sentTime,
  });

  Map<String, dynamic> toJson() => {
    'food': food.toJson(),
    'count': count,
    'isSentToKitchen': isSentToKitchen,
    'sentTime': sentTime?.toIso8601String(),
  };

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
    food: FoodModel.fromJson(json['food']),
    count: json['count'],
    isSentToKitchen: json['isSentToKitchen'] ?? false,
    sentTime: json['sentTime'] != null ? DateTime.parse(json['sentTime']) : null,
  );
}

// 后厨状态枚举
enum KitchenStatus { pending, sent, cooking, done }

// ===================== 菜品展示独立组件 =====================
class DianCanFoodSection extends StatefulWidget {
  final List<FoodModel> allFoods;
  final Function(FoodModel) onAddToCart; // 加购回调

  const DianCanFoodSection({
    super.key,
    required this.allFoods,
    required this.onAddToCart,
  });

  @override
  State<DianCanFoodSection> createState() => _DianCanFoodSectionState();
}

class _DianCanFoodSectionState extends State<DianCanFoodSection> {
  List<String> _categories = [];
  String _selectedCategory = '全部';
  List<FoodModel> _filteredFoods = [];
  TextEditingController _searchController = TextEditingController();
  String _searchKeyword = '';

  @override
  void initState() {
    super.initState();
    _initCategories();
    _filteredFoods = List.from(widget.allFoods);
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // 初始化分类（复用你的逻辑）
  void _initCategories() {
    Set<String> categorySet = {'全部'};
    for (var food in widget.allFoods) categorySet.add(food.category);
    _categories = categorySet.toList();
  }

  // 搜索变化（复用你的逻辑）
  void _onSearchChanged() {
    setState(() {
      _searchKeyword = _searchController.text.trim();
      _filterFoods();
    });
  }

  // 筛选菜品（复用你的逻辑）
  void _filterFoods() {
    List<FoodModel> tempList = _selectedCategory == '全部'
        ? List.from(widget.allFoods)
        : widget.allFoods.where((f) => f.category == _selectedCategory).toList();

    if (_searchKeyword.isNotEmpty) {
      tempList = tempList
          .where((f) => f.name.toLowerCase().contains(_searchKeyword.toLowerCase()))
          .toList();
    }

    _filteredFoods = tempList;
  }

  // 切换分类（复用你的逻辑）
  void _switchCategory(String category) {
    setState(() {
      _selectedCategory = category;
      _filterFoods();
    });
  }

  // 分类按钮（复用你的样式）
  Widget _buildCategoryBtn(String category) {
    bool isSelected = _selectedCategory == category;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: ElevatedButton(
        onPressed: () => _switchCategory(category),
        style: ElevatedButton.styleFrom(
          backgroundColor: isSelected ? const Color(0xFFD32F2F) : Colors.white,
          foregroundColor: isSelected ? Colors.white : Colors.black87,
          side: BorderSide(color: isSelected ? const Color(0xFFD32F2F) : Colors.grey[300]!),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          elevation: isSelected ? 3 : 1,
          minimumSize: const Size(60, 36),
        ),
        child: Text(
          category,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  // 菜品卡片（仅微调垂直间距）
  Widget _buildFoodCard(FoodModel food) {
    return GestureDetector(
      onTap: () => widget.onAddToCart(food),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.grey[300]!,
              blurRadius: 5,
              offset: const Offset(0, 3),
              spreadRadius: 1,
            )
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              child: Container(
                height: 50,
                width: double.infinity,
                decoration: BoxDecoration(color: Colors.grey[50]),
                child: food.imageUrl != null
                    ? Image.network(
                  food.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.restaurant,
                    color: Color(0xFFD32F2F),
                    size: 26,
                  ),
                )
                    : const Icon(
                  Icons.restaurant,
                  color: Color(0xFFD32F2F),
                  size: 26,
                ),
              ),
            ),
            // 修正点1：将垂直padding从4改为2，减少底部占用
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    food.name,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '¥${food.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFFD32F2F),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double screenWidth = MediaQuery.of(context).size.width;
    int foodCrossAxisCount = screenWidth > 1200 ? 5 : (screenWidth > 800 ? 4 : 3);

    return Column(
      children: [
        // 搜索框（复用你的样式）
        Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.grey[200]!,
                blurRadius: 4,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索菜品...',
              hintStyle: TextStyle(color: Colors.grey[500]),
              prefixIcon: const Icon(
                Icons.search,
                color: Color(0xFFD32F2F),
                size: 20,
              ),
              suffixIcon: _searchKeyword.isNotEmpty
                  ? IconButton(
                onPressed: () {
                  _searchController.clear();
                  _searchKeyword = '';
                  _filterFoods();
                },
                icon: const Icon(
                  Icons.clear,
                  color: Colors.grey,
                  size: 18,
                ),
              )
                  : null,
              filled: true,
              fillColor: Colors.grey[50],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            style: const TextStyle(fontSize: 14),
          ),
        ),
        // 分类栏（复用你的样式）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.grey[200]!,
                blurRadius: 3,
                offset: const Offset(0, 1),
              )
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: _categories.map((c) => _buildCategoryBtn(c)).toList(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // 菜品列表（复用你的样式）
        Expanded(
          child: _filteredFoods.isEmpty
              ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _searchKeyword.isNotEmpty ? Icons.search_off : Icons.restaurant_menu,
                  size: 60,
                  color: Colors.grey[300],
                ),
                const SizedBox(height: 12),
                Text(
                  _searchKeyword.isNotEmpty ? '未找到相关菜品' : '暂无该分类菜品',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          )
              : GridView.builder(
            padding: const EdgeInsets.all(10),
            physics: const BouncingScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: foodCrossAxisCount,
              childAspectRatio: 0.8,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _filteredFoods.length,
            itemBuilder: (_, i) => _buildFoodCard(_filteredFoods[i]),
          ),
        ),
      ],
    );
  }
}

// ===================== 购物车独立组件 =====================
class DianCanCartSection extends StatefulWidget {
  final List<CartItem> cartItems;
  final Map<int, KitchenStatus> kitchenStatusMap;
  final int zhuotaiId;
  final String zhuotaiTitle;
  final int peopleCount;
  final int wenxunId;
  final bool isAddFood;
  final Function(CartItem, bool) onAdjustCount; // 调整数量回调
  final Function(CartItem) onSendToKitchen; // 单个传后厨回调
  final Function() onBatchSendToKitchen; // 批量传后厨回调
  final Function(CartItem) onRemoveFromCart; // 删除菜品回调
  final Function() onPrintPreBill; // 打印预结单回调
  final Function() onCompleteAddFood; // 确认加菜回调
  final Function() onSubmitOrder; // 提交订单回调

  const DianCanCartSection({
    super.key,
    required this.cartItems,
    required this.kitchenStatusMap,
    required this.zhuotaiId,
    required this.zhuotaiTitle,
    required this.peopleCount,
    required this.wenxunId,
    required this.isAddFood,
    required this.onAdjustCount,
    required this.onSendToKitchen,
    required this.onBatchSendToKitchen,
    required this.onRemoveFromCart,
    required this.onPrintPreBill,
    required this.onCompleteAddFood,
    required this.onSubmitOrder,
  });

  @override
  State<DianCanCartSection> createState() => _DianCanCartSectionState();
}

class _DianCanCartSectionState extends State<DianCanCartSection> {
  // 计算总价（复用你的逻辑）
  double _calculateTotal() => widget.cartItems.fold(0.0, (t, i) => t + i.food.price * i.count);

  // 后厨状态样式（复用你的逻辑）
  Map<String, dynamic> _getKitchenStatusStyle(KitchenStatus status) {
    switch (status) {
      case KitchenStatus.pending:
        return {'text': '待传送', 'color': Colors.grey, 'bgColor': Colors.grey[100]};
      case KitchenStatus.sent:
        return {'text': '已传送', 'color': const Color(0xFF1976D2), 'bgColor': const Color(0xFFE3F2FD)};
      case KitchenStatus.cooking:
        return {'text': '烹饪中', 'color': const Color(0xFFF57C00), 'bgColor': const Color(0xFFFFF3E0)};
      case KitchenStatus.done:
        return {'text': '已出餐', 'color': const Color(0xFF2E7D32), 'bgColor': const Color(0xFFE8F5E9)};
    }
  }

  // 购物车项（微调对齐方式和间距）
  Widget _buildCartItem(CartItem item) {
    var status = _getKitchenStatusStyle(widget.kitchenStatusMap[item.food.id] ?? KitchenStatus.pending);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.grey[300]!,
            blurRadius: 5,
            offset: const Offset(0, 2),
            spreadRadius: 1,
          )
        ],
      ),
      // 修正点2：Row对齐方式改为顶部，避免内容挤到底部
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      item.food.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    Text(
                      '¥${item.food.price.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFD32F2F),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[300]!),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: () => widget.onAdjustCount(item, false),
                            icon: const Icon(Icons.remove, size: 14, color: Colors.grey),
                            padding: const EdgeInsets.all(2),
                            constraints: const BoxConstraints(minWidth: 22),
                            splashRadius: 14,
                          ),
                          Text(
                            '${item.count}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                          IconButton(
                            onPressed: () => widget.onAdjustCount(item, true),
                            icon: const Icon(Icons.add, size: 14, color: Color(0xFFD32F2F)),
                            padding: const EdgeInsets.all(2),
                            constraints: const BoxConstraints(minWidth: 22),
                            splashRadius: 14,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: status['bgColor'],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: status['color']!, width: 0.8),
                      ),
                      child: Text(
                        status['text'],
                        style: TextStyle(
                          fontSize: 10,
                          color: status['color'],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 修正点3：Column设为最小高度，避免占满空间
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 修正点4：底部margin从3改为2，减少间距
              Container(
                margin: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1976D2).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey[200]!,
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    )
                  ],
                ),
                child: IconButton(
                  onPressed: () => widget.onSendToKitchen(item),
                  icon: const Icon(
                    Icons.send,
                    size: 18,
                    color: Color(0xFF1976D2),
                  ),
                  padding: const EdgeInsets.all(5),
                  constraints: const BoxConstraints(minWidth: 32),
                  splashRadius: 18,
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFE64A19).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey[200]!,
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    )
                  ],
                ),
                child: IconButton(
                  onPressed: () => widget.onRemoveFromCart(item),
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Color(0xFFE64A19),
                  ),
                  padding: const EdgeInsets.all(5),
                  constraints: const BoxConstraints(minWidth: 32),
                  splashRadius: 18,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 购物车头部（复用你的样式）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFD32F2F),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 3,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '已点菜品',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  if (!widget.isAddFood)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      child: ElevatedButton(
                        onPressed: widget.onPrintPreBill,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.9),
                          foregroundColor: const Color(0xFFD32F2F),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          elevation: 0,
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.print, size: 12),
                            SizedBox(width: 4),
                            Text(
                              '预结单',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.cartItems.isNotEmpty)
                    ElevatedButton(
                      onPressed: widget.onBatchSendToKitchen,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.9),
                        foregroundColor: const Color(0xFFD32F2F),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        elevation: 0,
                      ),
                      child: const Text(
                        '批量传后厨',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        // 购物车列表（复用你的样式）
        Expanded(
          child: widget.cartItems.isEmpty
              ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.shopping_cart_outlined,
                  size: 80,
                  color: Colors.grey[200],
                ),
                const SizedBox(height: 16),
                Text(
                  widget.isAddFood ? '暂无新加菜品' : '暂无已点菜品',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '点击左侧菜品添加',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          )
              : ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 10),
            physics: const BouncingScrollPhysics(),
            itemCount: widget.cartItems.length,
            itemBuilder: (_, i) => _buildCartItem(widget.cartItems[i]),
          ),
        ),
        // 底部操作栏（复用你的样式）
        if (widget.cartItems.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 3,
                  offset: const Offset(0, -2),
                )
              ],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      widget.isAddFood ? '加菜总计' : '订单总计',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                    Text(
                      '¥${_calculateTotal().toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 18,
                        color: Color(0xFFD32F2F),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (widget.isAddFood)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: widget.onCompleteAddFood,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 3,
                      ),
                      child: const Text(
                        '确认加菜',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          child: ElevatedButton(
                            onPressed: widget.onPrintPreBill,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFFD32F2F),
                              side: const BorderSide(color: Color(0xFFD32F2F)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              elevation: 1,
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.print, size: 14),
                                SizedBox(width: 4),
                                Text(
                                  '打印预结单',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: widget.onSubmitOrder,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFD32F2F),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 3,
                          ),
                          child: const Text(
                            '提交订单',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ===================== 主点餐页面（整合拆分后的组件） =====================
class DianCanPage extends StatefulWidget {
  final int zhuotaiId;
  final String zhuotaiTitle;
  final int peopleCount;
  final int wenxunId;
  final bool isAddFood;
  final List<CartItem>? existingCartItems;

  const DianCanPage({
    super.key,
    required this.zhuotaiId,
    required this.zhuotaiTitle,
    required this.peopleCount,
    required this.wenxunId,
    this.isAddFood = false,
    this.existingCartItems,
  });

  @override
  State<DianCanPage> createState() => _DianCanPageState();
}

class _DianCanPageState extends State<DianCanPage> {
  List<FoodModel> _allFoods = [];
  List<CartItem> _cartItems = [];
  String get _cartStorageKey => 'diancan_cart_${widget.zhuotaiId}';
  Map<int, KitchenStatus> _kitchenStatusMap = {};

  @override
  void initState() {
    super.initState();
    _initFoodData();
    if (widget.isAddFood && widget.existingCartItems != null) {
      setState(() {
        _cartItems = List.from(widget.existingCartItems!);
      });
      _initKitchenStatus();
    } else {
      _loadCartFromLocal();
      _initKitchenStatus();
    }
  }

  // 初始化菜品数据（复用你的逻辑）
  void _initFoodData() {
    _allFoods = [
      FoodModel(
        id: 1,
        name: '麻辣小龙虾',
        category: '海鲜',
        price: 88.0,
        description: '秘制配方',
        imageUrl: 'https://img1.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 2,
        name: '蒜蓉小龙虾',
        category: '海鲜',
        price: 88.0,
        description: '蒜香浓郁',
        imageUrl: 'https://img2.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 3,
        name: '水煮鱼',
        category: '川菜',
        price: 68.0,
        description: '麻辣嫩滑',
        imageUrl: 'https://img0.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 4,
        name: '回锅肉',
        category: '川菜',
        price: 38.0,
        description: '肥而不腻',
        imageUrl: 'https://img2.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 5,
        name: '糖醋里脊',
        category: '鲁菜',
        price: 42.0,
        description: '酸甜可口',
        imageUrl: 'https://img0.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 6,
        name: '宫保鸡丁',
        category: '川菜',
        price: 36.0,
        description: '麻辣酸甜',
        imageUrl: 'https://img1.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 7,
        name: '清蒸鲈鱼',
        category: '海鲜',
        price: 78.0,
        description: '鲜嫩无刺',
        imageUrl: 'https://img2.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 8,
        name: '拍黄瓜',
        category: '凉菜',
        price: 18.0,
        description: '清爽解腻',
        imageUrl: 'https://img0.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 9,
        name: '佛跳墙',
        category: '闽菜',
        price: 198.0,
        description: '山珍海味',
        imageUrl: 'https://img1.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
      FoodModel(
        id: 10,
        name: '北京烤鸭',
        category: '京菜',
        price: 168.0,
        description: '皮脆肉嫩',
        imageUrl: 'https://img2.baidu.com/it/u=1234567890,1234567890&fm=253&fmt=auto&app=138&f=JPEG?w=800&h=500',
      ),
    ];
  }

  // 加载本地购物车（复用你的逻辑）
  Future<void> _loadCartFromLocal() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? cartJson = prefs.getString(_cartStorageKey);
    if (cartJson != null) {
      List<dynamic> cartList = json.decode(cartJson);
      setState(() => _cartItems = cartList.map((i) => CartItem.fromJson(i)).toList());
    }
  }

  // 保存购物车到本地（复用你的逻辑）
  Future<void> _saveCartToLocal() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> cartJsonList = _cartItems.map((i) => i.toJson()).toList();
    await prefs.setString(_cartStorageKey, json.encode(cartJsonList));
  }

  // 初始化后厨状态（复用你的逻辑）
  void _initKitchenStatus() {
    for (var item in _cartItems) {
      _kitchenStatusMap[item.food.id] = item.isSentToKitchen ? KitchenStatus.sent : KitchenStatus.pending;
    }
  }

  // 加购菜品（复用你的逻辑）
  void _addToCart(FoodModel food) {
    setState(() {
      int index = _cartItems.indexWhere((i) => i.food.id == food.id);
      if (index != -1) {
        _cartItems[index].count++;
      } else {
        _cartItems.add(CartItem(food: food));
        _kitchenStatusMap[food.id] = KitchenStatus.pending;
      }
      _saveCartToLocal();
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ 已加购【${food.name}】'),
      backgroundColor: const Color(0xFF2E7D32),
      duration: const Duration(milliseconds: 800),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  // 调整菜品数量（复用你的逻辑）
  void _adjustFoodCount(CartItem cartItem, bool isIncrease) {
    setState(() {
      int index = _cartItems.indexWhere((i) => i.food.id == cartItem.food.id);
      if (index != -1) {
        if (isIncrease) {
          _cartItems[index].count++;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ 【${cartItem.food.name}】数量+1'),
            backgroundColor: const Color(0xFF2E7D32),
            duration: const Duration(milliseconds: 600),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ));
        } else {
          if (_cartItems[index].count > 1) {
            _cartItems[index].count--;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('✅ 【${cartItem.food.name}】数量-1'),
              backgroundColor: const Color(0xFFFF9800),
              duration: const Duration(milliseconds: 600),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ));
          } else {
            _removeFromCart(cartItem);
            return;
          }
        }
        _saveCartToLocal();
      }
    });
  }

  // 删除菜品（复用你的逻辑）
  void _removeFromCart(CartItem cartItem) {
    setState(() {
      _cartItems.removeWhere((i) => i.food.id == cartItem.food.id);
      _kitchenStatusMap.remove(cartItem.food.id);
      _saveCartToLocal();
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('❌ 已退菜【${cartItem.food.name}】'),
      backgroundColor: const Color(0xFFE64A19),
      duration: const Duration(milliseconds: 800),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  // 单个传后厨（复用你的逻辑）
  void _sendToKitchen(CartItem cartItem) {
    if (cartItem.isSentToKitchen) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('【${cartItem.food.name}】已传后厨'),
        backgroundColor: const Color(0xFF1976D2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ));
      return;
    }

    setState(() {
      int index = _cartItems.indexWhere((i) => i.food.id == cartItem.food.id);
      if (index != -1) {
        _cartItems[index].isSentToKitchen = true;
        _cartItems[index].sentTime = DateTime.now();
        _kitchenStatusMap[cartItem.food.id] = KitchenStatus.sent;
        _saveCartToLocal();
      }
    });

    Future.delayed(const Duration(milliseconds: 500), () {
      setState(() => _kitchenStatusMap[cartItem.food.id] = KitchenStatus.cooking);
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('🚀 【${cartItem.food.name}】已传后厨'),
      backgroundColor: const Color(0xFF1976D2),
      duration: const Duration(milliseconds: 1000),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  // 批量传后厨（复用你的逻辑）
  void _batchSendToKitchen() {
    List<CartItem> unsent = _cartItems.where((i) => !i.isSentToKitchen).toList();
    if (unsent.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('所有菜品已传后厨'),
        backgroundColor: const Color(0xFF1976D2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ));
      return;
    }

    setState(() {
      for (var item in unsent) {
        int index = _cartItems.indexWhere((i) => i.food.id == item.food.id);
        if (index != -1) {
          _cartItems[index].isSentToKitchen = true;
          _cartItems[index].sentTime = DateTime.now();
          _kitchenStatusMap[item.food.id] = KitchenStatus.sent;
        }
      }
      _saveCartToLocal();
    });

    Future.delayed(const Duration(milliseconds: 800), () {
      for (var item in unsent) {
        setState(() => _kitchenStatusMap[item.food.id] = KitchenStatus.cooking);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('🚀 已批量传${unsent.length}个菜品到后厨'),
      backgroundColor: const Color(0xFF1976D2),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  // 打印预结单（复用你的逻辑）
  Future<void> _printPreBill() async {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('暂无菜品，无法打印预结单'),
        backgroundColor: const Color(0xFFE64A19),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ));
      return;
    }

    try {
      String billContent = """
========== 预结单 ==========
桌台：${widget.zhuotaiTitle} (ID: ${widget.zhuotaiId})
就餐人数：${widget.peopleCount}人
问询ID：${widget.wenxunId}
打印时间：${DateTime.now().toString().substring(0, 19)}
--------------------------
菜品列表：
${_cartItems.map((item) =>
      '${item.food.name} x${item.count}  ¥${(item.food.price * item.count).toStringAsFixed(2)}'
      ).join('\n')}
--------------------------
总计金额：¥${_calculateTotal().toStringAsFixed(2)}
========== 谢谢惠顾 ==========
""";

      await Future.delayed(const Duration(seconds: 1));

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('📄 ${widget.zhuotaiTitle} 预结单打印成功！'),
        backgroundColor: const Color(0xFF2E7D32),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 2),
      ));

      debugPrint('预结单内容：\n$billContent');

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('打印失败：$e'),
        backgroundColor: const Color(0xFFE64A19),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ));
    }
  }

  // 计算总价（复用你的逻辑）
  double _calculateTotal() => _cartItems.fold(0.0, (t, i) => t + i.food.price * i.count);

  // 确认加菜（复用你的逻辑）
  void _completeAddFood() {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('暂无新加菜品'),
        backgroundColor: const Color(0xFFE64A19),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ));
      return;
    }

    _saveCartToLocal();
    Navigator.pop(context, _cartItems);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ ${widget.zhuotaiTitle} 加菜成功！'),
      backgroundColor: const Color(0xFF2E7D32),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  // 提交订单（复用你的逻辑）
  void _submitOrder() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${widget.zhuotaiTitle} 订单提交成功！'),
      backgroundColor: const Color(0xFF2E7D32),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
    setState(() {
      _cartItems.clear();
      _kitchenStatusMap.clear();
      _saveCartToLocal();
    });
  }

  // 桌台操作弹窗（复用你的逻辑）
  void _showTableActionDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.5,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    '${widget.zhuotaiTitle} 操作选择',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const Divider(height: 1, color: Colors.grey),
                ListTile(
                  leading: const Icon(Icons.table_restaurant, color: Color(0xFFD32F2F)),
                  title: const Text('开台'),
                  onTap: () => Navigator.pop(context),
                  dense: true,
                ),
                const Divider(height: 1, color: Colors.grey),
                ListTile(
                  leading: const Icon(Icons.fastfood, color: Color(0xFFD32F2F)),
                  title: const Text('点餐'),
                  onTap: () => Navigator.pop(context),
                  dense: true,
                ),
                const Divider(height: 1, color: Colors.grey),
                ListTile(
                  leading: const Icon(Icons.cancel, color: Color(0xFFE64A19)),
                  title: const Text('取消订单'),
                  onTap: () => Navigator.pop(context),
                  dense: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: Column(
        children: [
          // 顶部导航栏（复用你的样式）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFD32F2F),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                  spreadRadius: 1,
                )
              ],
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: IconButton(
                    onPressed: () {
                      if (widget.isAddFood) {
                        Navigator.pop(context, _cartItems);
                      } else {
                        Navigator.pop(context);
                      }
                    },
                    icon: const Icon(
                      Icons.arrow_back_ios,
                      color: Colors.white,
                      size: 22,
                    ),
                    splashRadius: 28,
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.isAddFood ? '${widget.zhuotaiTitle} - 加菜' : widget.zhuotaiTitle,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '就餐人数：${widget.peopleCount}人',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 0,
                  child: TextButton(
                    onPressed: _showTableActionDialog,
                    child: const Text('测试弹窗', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
          // 主体内容：菜品展示 + 购物车
          Expanded(
            child: Row(
              children: [
                // 菜品展示区域（独立组件）
                Expanded(
                  flex: 7,
                  child: DianCanFoodSection(
                    allFoods: _allFoods,
                    onAddToCart: _addToCart,
                  ),
                ),
                // 购物车区域（独立组件）
                Expanded(
                  flex: 3,
                  child: Container(
                    margin: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey[200]!,
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        )
                      ],
                    ),
                    child: DianCanCartSection(
                      cartItems: _cartItems,
                      kitchenStatusMap: _kitchenStatusMap,
                      zhuotaiId: widget.zhuotaiId,
                      zhuotaiTitle: widget.zhuotaiTitle,
                      peopleCount: widget.peopleCount,
                      wenxunId: widget.wenxunId,
                      isAddFood: widget.isAddFood,
                      onAdjustCount: _adjustFoodCount,
                      onSendToKitchen: _sendToKitchen,
                      onBatchSendToKitchen: _batchSendToKitchen,
                      onRemoveFromCart: _removeFromCart,
                      onPrintPreBill: _printPreBill,
                      onCompleteAddFood: _completeAddFood,
                      onSubmitOrder: _submitOrder,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}