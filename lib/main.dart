// lib/main.dart
// 明日前瞻 - 智能过敏预警App

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '明日前瞻',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

// ========== 主页面 ==========
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // 状态变量
  String _riskLevel = "检测中...";
  String _riskMessage = "正在获取位置和花粉数据...";
  String _connectedDevice = "未连接";
  bool _isBleSupported = false;
  BluetoothDevice? _connectedDeviceObj;

  // 用户设置
  int _pollenThreshold = 50; // 花粉阈值
  int _uvThreshold = 5; // 紫外线阈值
  int _rainThreshold = 50; // 降雨阈值

  @override
  void initState() {
    super.initState();
    _initNotifications(); // 初始化推送
    _loadUserSettings(); // 加载用户设置
    _checkBluetooth(); // 检查蓝牙
    _startMonitoring(); // 开始监测
  }

  // 初始化推送通知
  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await flutterLocalNotificationsPlugin.initialize(settings);
  }

  // 加载用户保存的设置
  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _pollenThreshold = prefs.getInt('pollen_threshold') ?? 50;
      _uvThreshold = prefs.getInt('uv_threshold') ?? 5;
      _rainThreshold = prefs.getInt('rain_threshold') ?? 50;
    });
  }

  // 保存用户设置
  Future<void> _saveUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pollen_threshold', _pollenThreshold);
    await prefs.setInt('uv_threshold', _uvThreshold);
    await prefs.setInt('rain_threshold', _rainThreshold);
  }

  // 检查蓝牙
  void _checkBluetooth() async {
    if (await FlutterBluePlus.isSupported) {
      setState(() => _isBleSupported = true);
      _startScan();
    }
  }

  // 扫描挂件
  void _startScan() {
    FlutterBluePlus.startScan(timeout: Duration(seconds: 4));
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.name.contains("MingRi")) {
          setState(() => _connectedDevice = r.device.name);
          _connectedDeviceObj = r.device;
          r.device.connect();
          break;
        }
      }
    });
  }

  // 发送指令到挂件
  Future<void> _sendToPendant(String icon, String title, String value,
      String message, int level) async {
    if (_connectedDeviceObj == null) return;

    // 根据风险等级决定振动次数和LED颜色
    List<int> ledColor = [0, 0, 0]; // RGB
    int vibrateTimes = 1;

    if (level == 1) {
      // 低风险
      ledColor = [255, 255, 0]; // 黄
      vibrateTimes = 1;
    } else if (level == 2) {
      // 中风险
      ledColor = [255, 165, 0]; // 橙
      vibrateTimes = 2;
    } else if (level == 3) {
      // 高风险
      ledColor = [255, 0, 0]; // 红
      vibrateTimes = 3;
    }

    final command = {
      "type": "alert",
      "icon": icon,
      "title": title,
      "value": value,
      "message": message,
      "vibrate_times": vibrateTimes,
      "led": ledColor
    };

    // 通过蓝牙发送（需要找到对应的特征值）
    // 这里先简化，实际需要先发现服务
    // await characteristic.write(jsonEncode(command).codeUnits);
  }

  // 显示手机推送
  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'alerts',
      '过敏预警',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(0, title, body, details);
  }

  // 风险判断
  void _evaluateRisk(int pollen, int uv, int rainProb) async {
    String riskMsg = "";
    int level = 0;

    if (pollen > _pollenThreshold) {
      riskMsg = "⚠️ 花粉浓度高，建议戴口罩";
      level = 3;
    } else if (uv > _uvThreshold) {
      riskMsg = "☀️ 紫外线强，建议戴防晒口罩";
      level = 2;
    } else if (rainProb > _rainThreshold) {
      riskMsg = "☔ 可能下雨，建议带伞";
      level = 2;
    } else {
      riskMsg = "✅ 当前环境安全";
      level = 0;
    }

    setState(() {
      _riskMessage = riskMsg;
      if (level == 3)
        _riskLevel = "高风险";
      else if (level == 2)
        _riskLevel = "中风险";
      else if (level == 1)
        _riskLevel = "低风险";
      else
        _riskLevel = "安全";
    });

    // 有风险时发送提醒
    if (level > 0) {
      await _showNotification("明日前瞻提醒", riskMsg);
      await _sendToPendant("⚠️", _riskLevel, "", riskMsg, level);
    }
  }

  // 开始环境监测
  void _startMonitoring() async {
    // 获取GPS位置
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    Position position = await Geolocator.getCurrentPosition();
    double lat = position.latitude;
    double lon = position.longitude;

    // 模拟调用天气API（实际需要换你的API Key）
    // 这里用模拟数据演示
    _evaluateRisk(65, 7, 30);
  }

  // 显示设置对话框
  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("个性化设置"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Text("花粉阈值: $_pollenThreshold"),
              Expanded(
                child: Slider(
                  value: _pollenThreshold.toDouble(),
                  min: 0,
                  max: 100,
                  onChanged: (v) =>
                      setState(() => _pollenThreshold = v.toInt()),
                ),
              )
            ]),
            Row(children: [
              Text("紫外线阈值: $_uvThreshold"),
              Expanded(
                child: Slider(
                  value: _uvThreshold.toDouble(),
                  min: 0,
                  max: 11,
                  onChanged: (v) => setState(() => _uvThreshold = v.toInt()),
                ),
              )
            ]),
            Row(children: [
              Text("降雨阈值: $_rainThreshold%"),
              Expanded(
                child: Slider(
                  value: _rainThreshold.toDouble(),
                  min: 0,
                  max: 100,
                  onChanged: (v) => setState(() => _rainThreshold = v.toInt()),
                ),
              )
            ]),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _saveUserSettings();
              Navigator.pop(context);
            },
            child: Text("保存"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("明日前瞻"),
        actions: [
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            // 风险显示卡片
            Card(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Column(children: [
                  Text(_riskLevel,
                      style:
                          TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                  SizedBox(height: 10),
                  Text(_riskMessage, style: TextStyle(fontSize: 18)),
                ]),
              ),
            ),
            SizedBox(height: 20),
            // 蓝牙状态
            ListTile(
              leading: Icon(
                  _isBleSupported ? Icons.bluetooth : Icons.bluetooth_disabled),
              title: Text("挂件状态"),
              subtitle: Text(_connectedDevice),
            ),
            SizedBox(height: 20),
            // 自定义规则提示
            Container(
              padding: EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("💡 你可以这样说：",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text("• 紫外线超过5提醒我戴防晒口罩"),
                  Text("• 花粉浓度超过60提醒我戴口罩"),
                  Text("• 明天下雨提醒我带伞"),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startMonitoring,
        child: Icon(Icons.refresh),
        tooltip: '刷新检测',
      ),
    );
  }
}

// 推送通知插件
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
