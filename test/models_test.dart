import 'package:flutter_test/flutter_test.dart';
import 'package:audio_call_app/models/user_model.dart';
import 'package:audio_call_app/models/contact_model.dart';

void main() {
  group('UserModel Tests', () {
    test('fromJson and toJson matching backend response shapes', () {
      // Backend POST /users and GET /users/{id} return UserResponse
      final userResponseJson = {
        'id': 'user-uuid-123',
        'name': 'Alice Wonderland',
        'username': 'alice_w',
        'created_at': '2026-09-06T10:00:00Z',
        'is_online': true,
      };

      final user = UserModel.fromJson(userResponseJson);
      expect(user.id, 'user-uuid-123');
      expect(user.name, 'Alice Wonderland');
      expect(user.username, 'alice_w');

      final jsonOutput = user.toJson();
      expect(jsonOutput['id'], 'user-uuid-123');
      expect(jsonOutput['name'], 'Alice Wonderland');
      expect(jsonOutput['username'], 'alice_w');

      // Backend GET /users/search returns UserSearchResult items
      final searchResultJson = {
        'id': 'user-uuid-456',
        'name': 'Bob Builder',
        'username': 'bob_b',
        'is_online': false,
      };

      final searchUser = UserModel.fromJson(searchResultJson);
      expect(searchUser.id, 'user-uuid-456');
      expect(searchUser.name, 'Bob Builder');
      expect(searchUser.username, 'bob_b');
    });

    test('copyWith and equality', () {
      const user1 = UserModel(id: '1', name: 'User', username: 'user');
      final user2 = user1.copyWith(name: 'Updated User');

      expect(user2.id, '1');
      expect(user2.name, 'Updated User');
      expect(user2.username, 'user');
      expect(user1 == const UserModel(id: '1', name: 'User', username: 'user'), isTrue);
    });
  });

  group('ContactModel Tests', () {
    test('fromJson and toJson with backend ContactResponse', () {
      // Backend ContactResponse shape
      final contactResponseJson = {
        'id': 42,
        'user_id': 'owner-uuid-111',
        'contact_id': 'partner-uuid-222',
        'name': 'Charlie Chaplin',
        'username': 'charlie',
        'created_at': '2026-09-06T12:00:00Z',
        'is_online': true,
      };

      final contact = ContactModel.fromJson(contactResponseJson);
      expect(contact.id, 42); // Contact table record ID for DELETE
      expect(contact.contactUserId, 'partner-uuid-222');
      expect(contact.name, 'Charlie Chaplin');
      expect(contact.username, 'charlie');
      // isOnline is populated client-side later or defaults to false
      expect(contact.isOnline, isTrue);

      // Verify default when is_online is not in json
      final restJsonWithoutOnline = {
        'id': 99,
        'contact_id': 'partner-uuid-333',
        'name': 'Dave',
        'username': 'dave',
      };
      final contactWithoutOnline = ContactModel.fromJson(restJsonWithoutOnline);
      expect(contactWithoutOnline.id, 99);
      expect(contactWithoutOnline.contactUserId, 'partner-uuid-333');
      expect(contactWithoutOnline.isOnline, isFalse);

      final jsonOutput = contact.toJson();
      expect(jsonOutput['id'], 42);
      expect(jsonOutput['contact_id'], 'partner-uuid-222');
      expect(jsonOutput['contactUserId'], 'partner-uuid-222');
      expect(jsonOutput['name'], 'Charlie Chaplin');
      expect(jsonOutput['username'], 'charlie');
    });

    test('copyWith for client-side isOnline updates', () {
      const contact = ContactModel(
        id: 10,
        contactUserId: 'uuid-10',
        name: 'Eve',
        username: 'eve',
      );
      expect(contact.isOnline, isFalse);

      final onlineContact = contact.copyWith(isOnline: true);
      expect(onlineContact.id, 10);
      expect(onlineContact.contactUserId, 'uuid-10');
      expect(onlineContact.isOnline, isTrue);
    });
  });
}
