class ContactModel {
  /// The contact record's own database primary key ID (used for DELETE /contacts/{id}).
  final int id;

  /// The user ID of the contact partner (used for WebRTC calls / signaling).
  final String contactUserId;

  /// The contact's display name.
  final String name;

  /// The contact's phone number.
  final String phoneNumber;

  /// The contact's unique username (kept for backwards compatibility).
  final String username;

  /// Online presence status (nullable, defaults to false, populated client-side later).
  final bool? isOnline;

  const ContactModel({
    required this.id,
    required this.contactUserId,
    required this.name,
    this.phoneNumber = '',
    required this.username,
    this.isOnline = false,
  });

  /// Factory constructor to parse JSON response from the backend
  /// GET /contacts/{user_id} or POST /contacts.
  /// Note: isOnline defaults to false and is populated client-side later.
  factory ContactModel.fromJson(Map<String, dynamic> json) {
    final phone = (json['phone_number'] ??
            json['phoneNumber'] ??
            json['contact']?['phone_number'] ??
            json['contact']?['phoneNumber'] ??
            '')
        .toString();
    final user =
        (json['username'] ?? json['contact']?['username'] ?? '').toString();

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
      phoneNumber: phone.isNotEmpty ? phone : user,
      username: user.isNotEmpty ? user : phone,
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
      'phone_number': phoneNumber,
      'phoneNumber': phoneNumber,
      'username': username,
      'is_online': isOnline,
    };
  }

  ContactModel copyWith({
    int? id,
    String? contactUserId,
    String? name,
    String? phoneNumber,
    String? username,
    bool? isOnline,
  }) {
    return ContactModel(
      id: id ?? this.id,
      contactUserId: contactUserId ?? this.contactUserId,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
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
          phoneNumber == other.phoneNumber &&
          username == other.username &&
          isOnline == other.isOnline;

  @override
  int get hashCode =>
      id.hashCode ^
      contactUserId.hashCode ^
      name.hashCode ^
      phoneNumber.hashCode ^
      username.hashCode ^
      isOnline.hashCode;

  @override
  String toString() =>
      'ContactModel(id: $id, contactUserId: $contactUserId, name: $name, phoneNumber: $phoneNumber, username: $username, isOnline: $isOnline)';
}
