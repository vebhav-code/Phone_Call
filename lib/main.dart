import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/add_contact_screen.dart';
import 'screens/in_call_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'screens/main_shell.dart';
import 'screens/outgoing_call_screen.dart';
import 'screens/registration_screen.dart';
import 'screens/scam_screen.dart';
import 'services/call_controller.dart';
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
  final webrtcService = WebRTCService();
  final callController = CallController(
    signalingService: signalingService,
    webrtcService: webrtcService,
  );

  runApp(
    ChangeNotifierProvider<SignalingService>(
      create: (_) => signalingService,
      child: ChangeNotifierProvider<WebRTCService>(
        create: (_) => webrtcService,
        child: ChangeNotifierProvider<CallController>(
          create: (_) => callController,
          child: AudioCallApp(initialHasUser: hasUser),
        ),
      ),
    ),
  );
}

/// Screen identifiers for routing and navigation.
enum AppScreen {
  login,
  signup,
  registration,
  home,
  addContact,
  outgoingCall,
  incomingCall,
  inCall,
  scam,
}

/// Named route definitions and route generator for the app.
class AppRoutes {
  static const String login = '/login';
  static const String signup = '/signup';
  static const String registration = '/registration';
  static const String home = '/home';
  static const String addContact = '/add-contact';
  static const String outgoingCall = '/outgoing-call';
  static const String incomingCall = '/incoming-call';
  static const String inCall = '/in-call';
  static const String scam = '/scam';

  /// Maps an [AppScreen] enum value to its corresponding named route string.
  static String fromScreen(AppScreen screen) {
    switch (screen) {
      case AppScreen.login:
        return login;
      case AppScreen.signup:
        return signup;
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
      case AppScreen.scam:
        return scam;
    }
  }

  /// Centralized route generator for all named routes.
  static Route<dynamic>? onGenerateRoute(
    RouteSettings settings,
    BuildContext context,
  ) {
    final callController = ChangeNotifierProvider.maybeOf<CallController>(
      context,
      listen: false,
    );

    switch (settings.name) {
      case login:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const LoginScreen(),
        );

      case signup:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const SignupScreen(),
        );

      case registration:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const RegistrationScreen(),
        );

      case home:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => MainShell(
            callController: callController,
          ),
        );

      case scam:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const ScamScreen(),
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
            otherUserId: args['otherUserId'] as String?,
            callId: args['callId'] as String?,
            callController: callController,
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
            callController: callController,
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
            callController: callController,
            isReceiver: args['isReceiver'] as bool? ?? callController?.isReceiver ?? false,
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
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0066CC),
          primary: const Color(0xFF0066CC),
          surface: const Color(0xFFF8FAFC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A2540),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      initialRoute: initialHasUser ? AppRoutes.home : AppRoutes.registration,
      onGenerateRoute: (settings) =>
          AppRoutes.onGenerateRoute(settings, context),
    );
  }
}

/// A lightweight ChangeNotifierProvider implementation using InheritedNotifier.
class ChangeNotifierProvider<T extends ChangeNotifier> extends StatefulWidget {
  final T Function(BuildContext context) create;
  final Widget child;

  const ChangeNotifierProvider({
    super.key,
    required this.create,
    required this.child,
  });

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
