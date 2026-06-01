import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'firebase_options.dart';

const _adminPassword = 'admin123';
const _memoTopic = 'memo_all';

final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService.showRemoteMessage(message);
}

class NotificationService {
  static const _channelId = 'memo_channel';
  static const _channelName = 'Memo Reminders';

  static Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotificationsPlugin.initialize(settings);

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    FirebaseMessaging.onMessage.listen((message) {
      showRemoteMessage(message);
    });
  }

  static Future<void> requestPermissions() async {
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  static NotificationDetails get _notificationDetails {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Show scheduled memo reminders to the user.',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        threadIdentifier: 'memo_reminders',
      ),
    );
  }

  static Future<void> showRemoteMessage(RemoteMessage message) async {
    final title = message.notification?.title ?? message.data['title'] ?? 'Memo Reminder';
    final body = message.notification?.body ?? message.data['body'] ?? message.data['description'] ?? 'A memo has been created by admin.';
    final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);

    await _localNotificationsPlugin.show(
      id,
      title,
      body,
      _notificationDetails,
      payload: message.data['id'] ?? '',
    );
  }

  static Future<void> scheduleMemoNotification(Memo memo) async {
    if (memo.scheduledAt.isBefore(DateTime.now())) {
      await _localNotificationsPlugin.show(
        memo.notificationId,
        memo.title,
        memo.description,
        _notificationDetails,
      );
    } else {
      await _localNotificationsPlugin.zonedSchedule(
        memo.notificationId,
        memo.title,
        memo.description,
        tz.TZDateTime.from(memo.scheduledAt, tz.local),
        _notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
      );
    }
  }
}

class Memo {
  Memo({
    required this.id,
    required this.title,
    required this.description,
    required this.scheduledAt,
    required this.target,
    required this.notificationId,
  });

  final String id;
  final String title;
  final String description;
  final DateTime scheduledAt;
  final String target;
  final int notificationId;

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String,
      scheduledAt: (json['scheduledAt'] as Timestamp).toDate(),
      target: json['target'] as String? ?? 'all',
      notificationId: json['notificationId'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'target': target,
      'notificationId': notificationId,
    };
  }
}

class MemoScheduler {
  static const _scheduledIdsKey = 'scheduled_memo_ids';

  static Future<void> scheduleMemos(List<Memo> memos) async {
    if (kIsWeb) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final scheduledIds = prefs.getStringList(_scheduledIdsKey) ?? [];
    final upcoming = memos.where((memo) => memo.scheduledAt.isAfter(DateTime.now()));

    for (final memo in upcoming) {
      if (!scheduledIds.contains(memo.id)) {
        await NotificationService.scheduleMemoNotification(memo);
        scheduledIds.add(memo.id);
      }
    }

    await prefs.setStringList(_scheduledIdsKey, scheduledIds);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.web);
  } else {
    await Firebase.initializeApp();
  }

  if (!kIsWeb) {
    tz.initializeTimeZones();
    await NotificationService.initialize();
    await NotificationService.requestPermissions();
    await FirebaseMessaging.instance.subscribeToTopic(_memoTopic);
  }

  runApp(const MemoApp());
}

class MemoApp extends StatelessWidget {
  const MemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Memo Reminders',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _collection = FirebaseFirestore.instance.collection('memos');
  final List<Memo> _memos = [];
  bool _isAdmin = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _listenToMemos();
  }

  void _listenToMemos() {
    _collection.orderBy('scheduledAt').snapshots().listen((snapshot) async {
      final memos = snapshot.docs
          .map((doc) => Memo.fromJson(doc.data()))
          .toList();
      if (mounted) {
        setState(() {
          _memos
            ..clear()
            ..addAll(memos);
          _loading = false;
        });
      }
      await MemoScheduler.scheduleMemos(memos);
    });
  }

  Future<void> _enterAdminMode() async {
    final password = await showDialog<String?>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Admin Password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Enter'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    if (password == _adminPassword) {
      setState(() {
        _isAdmin = true;
      });
      final created = await Navigator.of(context).push<Memo>(
        MaterialPageRoute(builder: (_) => const CreateMemoPage()),
      );
      if (!mounted) return;
      if (created != null) {
        await _collection.doc(created.id).set(created.toJson());
      }
    } else if (password != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid admin password.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memo Reminders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: _enterAdminMode,
            tooltip: 'Admin mode',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Welcome! You will receive memo reminders once the time is reached.',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'All users get messages automatically after installing the app.',
                    style: TextStyle(fontSize: 14, color: Colors.black54),
                  ),
                  if (_isAdmin)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Admin mode active: create memos for all users using the button above.',
                        style: TextStyle(color: Colors.indigo, fontWeight: FontWeight.w600),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: _memos.isEmpty
                        ? const Center(
                            child: Text(
                              'No memos yet. Admin can create a reminder for all users.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            itemCount: _memos.length,
                            itemBuilder: (context, index) {
                              final memo = _memos[index];
                              return MemoCard(memo: memo);
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

class MemoCard extends StatelessWidget {
  const MemoCard({super.key, required this.memo});

  final Memo memo;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              memo.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(memo.description),
            const SizedBox(height: 12),
            Text(
              'Scheduled: ${memo.scheduledAt.year}/${memo.scheduledAt.month.toString().padLeft(2, '0')}/${memo.scheduledAt.day.toString().padLeft(2, '0')} ${memo.scheduledAt.hour.toString().padLeft(2, '0')}:${memo.scheduledAt.minute.toString().padLeft(2, '0')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class CreateMemoPage extends StatefulWidget {
  const CreateMemoPage({super.key});

  @override
  State<CreateMemoPage> createState() => _CreateMemoPageState();
}

class _CreateMemoPageState extends State<CreateMemoPage> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  String? _errorText;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 2),
    );
    if (date != null) {
      setState(() {
        _selectedDate = date;
      });
    }
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time != null) {
      setState(() {
        _selectedTime = time;
      });
    }
  }

  void _submit() {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();

    if (title.isEmpty || description.isEmpty) {
      setState(() {
        _errorText = 'Title and description are required.';
      });
      return;
    }

    if (_selectedDate == null || _selectedTime == null) {
      setState(() {
        _errorText = 'Please choose a date and time for the memo.';
      });
      return;
    }

    final scheduled = DateTime(
      _selectedDate!.year,
      _selectedDate!.month,
      _selectedDate!.day,
      _selectedTime!.hour,
      _selectedTime!.minute,
    );

    if (scheduled.isBefore(DateTime.now())) {
      setState(() {
        _errorText = 'Scheduled time must be in the future.';
      });
      return;
    }

    final memo = Memo(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      description: description,
      scheduledAt: scheduled,
      target: 'all',
      notificationId: DateTime.now().millisecondsSinceEpoch.remainder(100000),
    );

    Navigator.of(context).pop(memo);
  }

  @override
  Widget build(BuildContext context) {
    final scheduledText = _selectedDate == null || _selectedTime == null
        ? 'Pick date and time'
        : '${_selectedDate!.year}/${_selectedDate!.month.toString().padLeft(2, '0')}/${_selectedDate!.day.toString().padLeft(2, '0')} ${_selectedTime!.format(context)}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Memo for All Users'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Memo Title'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Memo Description'),
                minLines: 3,
                maxLines: 5,
              ),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                icon: const Icon(Icons.calendar_month),
                label: Text(scheduledText),
                onPressed: () async {
                  await _pickDate();
                  if (_selectedDate != null) {
                    await _pickTime();
                  }
                },
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: _submit,
                child: const Text('Save Memo for All Users'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
