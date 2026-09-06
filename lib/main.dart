import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/add_contact_screen.dart';
import 'screens/home_screen.dart';
import 'screens/in_call_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'screens/outgoing_call_screen.dart';
import 'screens/registration_screen.dart';
import 'services/signaling_service.dart';
import 'webrtc_service.dart';

export 'screens/in_call_screen.dart' show AudioPulseIndicator, InCallScreen;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final String? userId = prefs.getString('user_id');
  final bool hasUser = userId != null && userId.isNotEmpty;

  final signalingService = SignalingService();
  if (hasUser) {
    signalingService.connect(userId);
  }
  final webrtcService = WebRTCService(signalingService: signalingService);

  runApp(
    ChangeNotifierProvider<SignalingService>(
      create: (_) => signalingService,
      child: ChangeNotifierProvider<WebRTCService>(
        create: (_) => webrtcService,
        child: AudioCallApp(initialHasUser: hasUser),
      ),
    ),
  );
}

/// Screen identifiers for routing and navigation.
enum AppScreen {
  registration,
  home,
  addContact,
  outgoingCall,
  incomingCall,
  inCall,
}

/// Named route definitions and route generator for the app.
class AppRoutes {
  static const String registration = '/registration';
  static const String home = '/home';
  static const String addContact = '/add-contact';
  static const String outgoingCall = '/outgoing-call';
  static const String incomingCall = '/incoming-call';
  static const String inCall = '/in-call';

  /// Maps an [AppScreen] enum value to its corresponding named route string.
  static String fromScreen(AppScreen screen) {
    switch (screen) {
      case AppScreen.registration:
        return registration;
      case AppScreen.home:
        return home;
      case AppScreen.addContact:
        return addContact;
      case AppScreen.outgoingCall:
        return outgoingCall;
      case AppScreen.incomingCall:
        return incomingCall;
      case AppScreen.inCall:
        return inCall;
    }
  }

  /// Centralized route generator for all named routes.
  static Route<dynamic>? onGenerateRoute(
    RouteSettings settings,
    BuildContext context,
  ) {
    final signaling = ChangeNotifierProvider.maybeOf<SignalingService>(
      context,
      listen: false,
    );
    final webrtc = ChangeNotifierProvider.maybeOf<WebRTCService>(
      context,
      listen: false,
    );

    switch (settings.name) {
      case registration:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const RegistrationScreen(),
        );

      case home:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => HomeScreen(
            signalingService: signaling,
            webrtcService: webrtc,
          ),
        );

      case addContact:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const AddContactScreen(),
        );

      case outgoingCall:
        final args = settings.arguments as Map<String, dynamic>? ?? {};
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => OutgoingCallScreen(
            contactName: args['contactName'] as String? ?? 'Contact',
            callId: args['callId'] as String? ?? '',
            otherUserId: args['otherUserId'] as String?,
            signalingService: signaling,
            webrtcService: webrtc,
          ),
        );

      case incomingCall:
        final args = settings.arguments as Map<String, dynamic>? ?? {};
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => IncomingCallScreen(
            callerName: args['callerName'] as String? ?? 'Unknown Caller',
            callerId: args['callerId'] as String? ?? '',
            callId: args['callId'] as String? ?? '',
            signalingService: signaling,
            webrtcService: webrtc,
          ),
        );

      case inCall:
        final args = settings.arguments as Map<String, dynamic>? ?? {};
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => InCallScreen(
            otherUserName: args['otherUserName'] as String? ?? 'Call',
            callId: args['callId'] as String? ?? '',
            otherUserId: args['otherUserId'] as String?,
            signalingService: signaling,
            webrtcService: webrtc,
          ),
        );

      default:
        return null;
    }
  }
}

/// Root widget configuring MaterialApp, theme, and initial route.
class AudioCallApp extends StatelessWidget {
  final bool initialHasUser;

  const AudioCallApp({super.key, this.initialHasUser = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebRTC Audio Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      initialRoute: initialHasUser ? AppRoutes.home : AppRoutes.registration,
      onGenerateRoute: (settings) =>
          AppRoutes.onGenerateRoute(settings, context),
    );
  }
}

/// A lightweight ChangeNotifierProvider implementation to inject and access
/// dependencies in the widget tree using standard Flutter primitives (InheritedNotifier).
class ChangeNotifierProvider<T extends ChangeNotifier> extends StatefulWidget {
  final T Function(BuildContext context) create;
  final Widget child;

  const ChangeNotifierProvider({
    super.key,
    required this.create,
    required this.child,
  });

  /// Obtains the [T] instance from the closest [ChangeNotifierProvider] ancestor,
  /// throwing an assertion error if none is found.
  static T of<T extends ChangeNotifier>(
    BuildContext context, {
    bool listen = true,
  }) {
    if (listen) {
      final inherited = context
          .dependOnInheritedWidgetOfExactType<_InheritedNotifier<T>>();
      assert(inherited?.notifier != null,
          'No ChangeNotifierProvider<$T> found in context');
      return inherited!.notifier!;
    } else {
      final element = context
          .getElementForInheritedWidgetOfExactType<_InheritedNotifier<T>>();
      final inherited = element?.widget as _InheritedNotifier<T>?;
      assert(inherited?.notifier != null,
          'No ChangeNotifierProvider<$T> found in context');
      return inherited!.notifier!;
    }
  }

  /// Safely obtains the [T] instance from the closest [ChangeNotifierProvider] ancestor,
  /// returning null if none is found.
  static T? maybeOf<T extends ChangeNotifier>(
    BuildContext context, {
    bool listen = true,
  }) {
    if (listen) {
      final inherited = context
          .dependOnInheritedWidgetOfExactType<_InheritedNotifier<T>>();
      return inherited?.notifier;
    } else {
      final element = context
          .getElementForInheritedWidgetOfExactType<_InheritedNotifier<T>>();
      final inherited = element?.widget as _InheritedNotifier<T>?;
      return inherited?.notifier;
    }
  }

  @override
  State<ChangeNotifierProvider<T>> createState() =>
      _ChangeNotifierProviderState<T>();
}

class _ChangeNotifierProviderState<T extends ChangeNotifier>
    extends State<ChangeNotifierProvider<T>> {
  late final T _service;

  @override
  void initState() {
    super.initState();
    _service = widget.create(context);
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _InheritedNotifier<T>(
      notifier: _service,
      child: widget.child,
    );
  }
}

class _InheritedNotifier<T extends ChangeNotifier> extends InheritedNotifier<T> {
  const _InheritedNotifier({
    super.key,
    required super.notifier,
    required super.child,
  });
}
