import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:audio_call_app/models/voice_detection_model.dart';
import 'package:audio_call_app/screens/in_call_screen.dart';
import 'package:audio_call_app/services/api_service.dart';
import 'package:audio_call_app/services/voice_detection_service.dart';

/// Test double for [RemoteAudioRecorder].
class MockRemoteAudioRecorder implements RemoteAudioRecorder {
  bool isStarted = false;
  bool isStopped = false;
  bool isDisposed = false;
  String? lastRecordedPath;
  bool shouldFailOnStart = false;
  bool writeDummyDataOnStart = true;

  @override
  Future<void> start(String path, {dynamic remoteStream}) async {
    if (shouldFailOnStart) {
      throw Exception('Recorder initialization failed');
    }
    isStarted = true;
    lastRecordedPath = path;
    if (writeDummyDataOnStart) {
      final file = File(path);
      await file.writeAsBytes([0xFF, 0xFB, 0x90, 0x64]); // Dummy MP3 sync frame
    }
  }

  @override
  Future<void> stop() async {
    isStopped = true;
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
  }
}

/// Controllable test double for [VoiceDetectionService] for deterministic UI testing.
class TestVoiceDetectionService extends VoiceDetectionService {
  VoiceAnalysisStatus _mockStatus = VoiceAnalysisStatus.idle;
  VoiceDetectionResult? _mockResult;

  @override
  VoiceAnalysisStatus get status => _mockStatus;

  @override
  VoiceDetectionResult? get result => _mockResult;

  void emitStatus(VoiceAnalysisStatus newStatus, [VoiceDetectionResult? newResult]) {
    _mockStatus = newStatus;
    _mockResult = newResult;
    notifyListeners();
  }
}

void main() {
  group('VoiceDetectionResult Model Tests', () {
    test('parses REAL verdict with scores correctly', () {
      final json = {
        'success': true,
        'fake_probability': 0.1338,
        'bonafide_score': 0.8662,
        'verdict': 'REAL',
      };
      final result = VoiceDetectionResult.fromJson(json);

      expect(result.success, isTrue);
      expect(result.fakeProbability, 0.1338);
      expect(result.bonafideScore, 0.8662);
      expect(result.verdict, 'REAL');
      expect(result.displayVerdict, 'REAL');
      expect(result.displayBonafideScore, '86.62%');
      expect(result.displayFakeProbability, '13.38%');
    });

    test('parses FAKE verdict with scores correctly', () {
      final json = {
        'success': true,
        'fake_probability': 0.95,
        'bonafide_score': 0.05,
        'verdict': 'FAKE',
      };
      final result = VoiceDetectionResult.fromJson(json);

      expect(result.success, isTrue);
      expect(result.verdict, 'FAKE');
      expect(result.displayVerdict, 'FAKE');
      expect(result.displayFakeProbability, '95%');
      expect(result.displayBonafideScore, '5%');
    });

    test('parses failure response with message', () {
      final json = {
        'success': false,
        'message': 'Voice detection failed',
      };
      final result = VoiceDetectionResult.fromJson(json);

      expect(result.success, isFalse);
      expect(result.message, 'Voice detection failed');
      expect(result.displayVerdict, 'UNKNOWN');
    });
  });

  group('ApiService.detectVoice Tests', () {
    test('detectVoiceBytes successfully sends multipart file and receives new result schema', () async {
      final mockClient = http_testing.MockClient((request) async {
        expect(request.url.path, '/voice-detection');
        expect(request.method, 'POST');
        expect(request.headers['content-type'], contains('multipart/form-data'));

        return http.Response(
          jsonEncode({
            'success': true,
            'fake_probability': 0.1338,
            'bonafide_score': 0.8662,
            'verdict': 'REAL',
          }),
          200,
        );
      });

      final apiService = ApiService(baseUrl: 'https://test-server.com', client: mockClient);
      final result = await apiService.detectVoiceBytes([1, 2, 3, 4]);

      expect(result.success, isTrue);
      expect(result.displayVerdict, 'REAL');
      expect(result.displayBonafideScore, '86.62%');
      expect(result.displayFakeProbability, '13.38%');
    });

    test('detectVoice throws ApiException on HTTP 500', () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'Internal server error'}),
          500,
        );
      });

      final apiService = ApiService(baseUrl: 'https://test-server.com', client: mockClient);

      expect(
        () => apiService.detectVoiceBytes([1, 2, 3, 4]),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('VoiceDetectionService Lifecycle Tests', () {
    test('completes 10s recording, uploads MP3, and displays result with verdict and scores', () async {
      final mockRecorder = MockRemoteAudioRecorder();
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'fake_probability': 0.1338,
            'bonafide_score': 0.8662,
            'verdict': 'REAL',
          }),
          200,
        );
      });

      final apiService = ApiService(baseUrl: 'https://test.com', client: mockClient);
      final service = VoiceDetectionService(
        apiService: apiService,
        recorder: mockRecorder,
        recordingDuration: const Duration(milliseconds: 50),
      );

      expect(service.status, VoiceAnalysisStatus.idle);

      await service.startAnalysis(isCallActive: () => true);

      expect(service.status, VoiceAnalysisStatus.recording);
      expect(mockRecorder.isStarted, isTrue);
      expect(service.isRecording, isTrue);

      // Wait for the timer to elapse and complete upload
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(mockRecorder.isStopped, isTrue);
      expect(service.status, VoiceAnalysisStatus.success);
      expect(service.result?.displayVerdict, 'REAL');
      expect(service.result?.displayBonafideScore, '86.62%');
      expect(service.result?.displayFakeProbability, '13.38%');

      // Temporary MP3 should have been cleaned up
      if (mockRecorder.lastRecordedPath != null) {
        expect(File(mockRecorder.lastRecordedPath!).existsSync(), isFalse);
      }

      service.dispose();
    });

    test('aborts and deletes temporary recording if call ends before duration', () async {
      final mockRecorder = MockRemoteAudioRecorder();
      bool uploadAttempted = false;

      final mockClient = http_testing.MockClient((request) async {
        uploadAttempted = true;
        return http.Response('{}', 200);
      });

      final apiService = ApiService(baseUrl: 'https://test.com', client: mockClient);
      final service = VoiceDetectionService(
        apiService: apiService,
        recorder: mockRecorder,
        recordingDuration: const Duration(milliseconds: 200),
      );

      bool callActive = true;
      await service.startAnalysis(isCallActive: () => callActive);

      expect(service.status, VoiceAnalysisStatus.recording);

      // Call ends prematurely before duration
      callActive = false;
      service.cancel();

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(uploadAttempted, isFalse);
      if (mockRecorder.lastRecordedPath != null) {
        expect(File(mockRecorder.lastRecordedPath!).existsSync(), isFalse);
      }

      service.dispose();
    });

    test('ignores duplicate startAnalysis calls (runs only ONCE)', () async {
      final mockRecorder = MockRemoteAudioRecorder();
      final service = VoiceDetectionService(
        recorder: mockRecorder,
        recordingDuration: const Duration(seconds: 10),
      );

      await service.startAnalysis(isCallActive: () => true);
      final firstPath = mockRecorder.lastRecordedPath;

      // Second start attempt
      await service.startAnalysis(isCallActive: () => true);
      expect(mockRecorder.lastRecordedPath, equals(firstPath));

      service.cancel();
      service.dispose();
    });

    test('handles recording failure gracefully without throwing or ending call', () async {
      final mockRecorder = MockRemoteAudioRecorder()..shouldFailOnStart = true;
      final service = VoiceDetectionService(
        recorder: mockRecorder,
        recordingDuration: const Duration(milliseconds: 50),
      );

      await service.startAnalysis(isCallActive: () => true);

      expect(service.status, VoiceAnalysisStatus.recordingFailed);
      expect(service.errorMessage, 'Voice recording failed');

      service.dispose();
    });

    test('handles upload failure gracefully by setting uploadFailed status', () async {
      final mockRecorder = MockRemoteAudioRecorder();
      final mockClient = http_testing.MockClient((request) async {
        throw const SocketException('No Internet');
      });

      final apiService = ApiService(baseUrl: 'https://test.com', client: mockClient);
      final service = VoiceDetectionService(
        apiService: apiService,
        recorder: mockRecorder,
        recordingDuration: const Duration(milliseconds: 50),
      );

      await service.startAnalysis(isCallActive: () => true);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(service.status, VoiceAnalysisStatus.uploadFailed);
      expect(service.errorMessage, 'Voice analysis unavailable');

      service.dispose();
    });

    test('handles backend AI detection failure (success: false)', () async {
      final mockRecorder = MockRemoteAudioRecorder();
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': false,
            'message': 'Voice detection failed',
          }),
          200,
        );
      });

      final apiService = ApiService(baseUrl: 'https://test.com', client: mockClient);
      final service = VoiceDetectionService(
        apiService: apiService,
        recorder: mockRecorder,
        recordingDuration: const Duration(milliseconds: 50),
      );

      await service.startAnalysis(isCallActive: () => true);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(service.status, VoiceAnalysisStatus.analysisFailed);
      expect(service.errorMessage, 'Voice detection failed');

      service.dispose();
    });

    test('reports recording failure when recorded file is missing or empty (does not call API)', () async {
      final mockRecorder = MockRemoteAudioRecorder()..writeDummyDataOnStart = false;
      bool uploadAttempted = false;

      final mockClient = http_testing.MockClient((request) async {
        uploadAttempted = true;
        return http.Response('{}', 200);
      });

      final apiService = ApiService(baseUrl: 'https://test.com', client: mockClient);
      final service = VoiceDetectionService(
        apiService: apiService,
        recorder: mockRecorder,
        recordingDuration: const Duration(milliseconds: 50),
      );

      await service.startAnalysis(isCallActive: () => true);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(uploadAttempted, isFalse);
      expect(service.status, VoiceAnalysisStatus.recordingFailed);
      expect(service.errorMessage, 'Voice recording failed');

      service.dispose();
    });
  });

  group('InCallScreen Receiver UI Tests', () {
    testWidgets('receiver screen displays all voice analysis states with verdict and scores', (tester) async {
      final testService = TestVoiceDetectionService();

      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Alice',
            callId: 'test-call-123',
            isReceiver: true,
            voiceDetectionService: testService,
          ),
        ),
      );

      // 1. Idle -> nothing shown
      expect(find.byKey(const Key('voice_analysis_recording')), findsNothing);
      expect(find.byKey(const Key('voice_analysis_analyzing')), findsNothing);
      expect(find.byKey(const Key('voice_analysis_result')), findsNothing);

      // 2. Recording state
      testService.emitStatus(VoiceAnalysisStatus.recording);
      await tester.pump();
      expect(find.text('Voice analysis recording...'), findsOneWidget);
      expect(find.byKey(const Key('voice_analysis_recording')), findsOneWidget);

      // 3. Analyzing state
      testService.emitStatus(VoiceAnalysisStatus.analyzing);
      await tester.pump();
      expect(find.text('Analyzing voice...'), findsOneWidget);
      expect(find.byKey(const Key('voice_analysis_analyzing')), findsOneWidget);

      // 4. Success state (REAL)
      testService.emitStatus(
        VoiceAnalysisStatus.success,
        const VoiceDetectionResult(
          success: true,
          fakeProbability: 0.1338,
          bonafideScore: 0.8662,
          verdict: 'REAL',
        ),
      );
      await tester.pump();
      expect(find.text('Voice Analysis'), findsOneWidget);
      expect(find.text('REAL'), findsOneWidget);
      expect(find.text('Bonafide Score: 86.62%'), findsOneWidget);
      expect(find.text('Fake Probability: 13.38%'), findsOneWidget);
      expect(find.byKey(const Key('voice_analysis_result')), findsOneWidget);

      // 5. Success state (FAKE)
      testService.emitStatus(
        VoiceAnalysisStatus.success,
        const VoiceDetectionResult(
          success: true,
          fakeProbability: 0.95,
          bonafideScore: 0.05,
          verdict: 'FAKE',
        ),
      );
      await tester.pump();
      expect(find.text('Voice Analysis'), findsOneWidget);
      expect(find.text('FAKE'), findsOneWidget);
      expect(find.text('Fake Probability: 95%'), findsOneWidget);
      expect(find.text('Bonafide Score: 5%'), findsOneWidget);

      // 6. Recording failed
      testService.emitStatus(VoiceAnalysisStatus.recordingFailed);
      await tester.pump();
      expect(find.text('Voice recording failed'), findsOneWidget);
      expect(find.byKey(const Key('voice_analysis_recording_failed')), findsOneWidget);

      // 7. Upload failed
      testService.emitStatus(VoiceAnalysisStatus.uploadFailed);
      await tester.pump();
      expect(find.text('Voice analysis unavailable'), findsOneWidget);
      expect(find.byKey(const Key('voice_analysis_upload_failed')), findsOneWidget);

      // 8. Analysis failed
      testService.emitStatus(VoiceAnalysisStatus.analysisFailed);
      await tester.pump();
      expect(find.text('Voice analysis failed'), findsOneWidget);
      expect(find.byKey(const Key('voice_analysis_failed')), findsOneWidget);

      testService.dispose();
    });

    testWidgets('caller screen (isReceiver: false) does NOT show voice analysis', (tester) async {
      final testService = TestVoiceDetectionService();

      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Charlie',
            callId: 'test-call-789',
            isReceiver: false,
            voiceDetectionService: testService,
          ),
        ),
      );

      testService.emitStatus(VoiceAnalysisStatus.recording);
      await tester.pump();

      // None of the voice analysis UI elements should be present on caller screen
      expect(find.byKey(const Key('voice_analysis_recording')), findsNothing);
      expect(find.byKey(const Key('voice_analysis_analyzing')), findsNothing);
      expect(find.byKey(const Key('voice_analysis_result')), findsNothing);

      testService.dispose();
    });
  });
}
