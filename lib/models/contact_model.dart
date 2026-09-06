class ContactModel {
  /// The contact record's own database primary key ID (used for DELETE /contacts/{id}).
  final int id;

  /// The user ID of the contact partner (used for WebRTC calls / signaling).
  final String contactUserId;

  /// The contact's display name.
  final String name;

  /// The contact's unique username.
  final String username;

  /// Online presence status (nullable, defaults to false, populated client-side later).
  final bool? isOnline;

  const ContactModel({
    required this.id,
    required this.contactUserId,
    required this.name,
    required this.username,
    this.isOnline = false,
  });

  /// Factory constructor to parse JSON response from the backend
  /// GET /contacts/{user_id} or POST /contacts.
  /// Note: isOnline defaults to false and is populated client-side later.
  factory ContactModel.fromJson(Map<String, dynamic> json) {
    return ContactModel(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      contactUserId: (json['contact_id'] ??
              json['contactUserId'] ??
              json['contact']?['id'] ??
              '')
          .toString(),
      name: (json['name'] ?? json['contact']?['name'] ?? '').toString(),
      username:
          (json['username'] ?? json['contact']?['username'] ?? '').toString(),
      isOnline: json['is_online'] is bool
          ? json['is_online'] as bool
          : (json['isOnline'] is bool ? json['isOnline'] as bool : false),
    );
  }

  /// Converts the ContactModel into a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'contact_id': contactUserId,
      'contactUserId': contactUserId,
      'name': name,
      'username': username,
      'is_online': isOnline,
    };
  }

  ContactModel copyWith({
    int? id,
    String? contactUserId,
    String? name,
    String? username,
    bool? isOnline,
  }) {
    return ContactModel(
      id: id ?? this.id,
      contactUserId: contactUserId ?? this.contactUserId,
      name: name ?? this.name,
      username: username ?? this.username,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactModel &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          contactUserId == other.contactUserId &&
          name == other.name &&
          username == other.username &&
          isOnline == other.isOnline;

  @override
  int get hashCode =>
      id.hashCode ^
      contactUserId.hashCode ^
      name.hashCode ^
      username.hashCode ^
      isOnline.hashCode;

  @override
  String toString() =>
      'ContactModel(id: $id, contactUserId: $contactUserId, name: $name, username: $username, isOnline: $isOnline)';
}
