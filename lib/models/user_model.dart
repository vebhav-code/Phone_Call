class UserModel {
  final String id;
  final String name;
  final String phoneNumber;
  final String username;

  const UserModel({
    required this.id,
    required this.name,
    this.phoneNumber = '',
    required this.username,
  });

  /// Factory constructor to parse JSON response from the backend
  /// matching POST /users, GET /users/search, and GET /users/{id}.
  factory UserModel.fromJson(Map<String, dynamic> json) {
    final phone = (json['phone_number'] ?? json['phoneNumber'] ?? '').toString();
    final user = (json['username'] ?? '').toString();
    return UserModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      phoneNumber: phone.isNotEmpty ? phone : user,
      username: user.isNotEmpty ? user : phone,
    );
  }

  /// Converts the UserModel into a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'phone_number': phoneNumber,
      'phoneNumber': phoneNumber,
      'username': username,
    };
  }

  UserModel copyWith({
    String? id,
    String? name,
    String? phoneNumber,
    String? username,
  }) {
    return UserModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      username: username ?? this.username,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserModel &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          phoneNumber == other.phoneNumber &&
          username == other.username;

  @override
  int get hashCode =>
      id.hashCode ^ name.hashCode ^ phoneNumber.hashCode ^ username.hashCode;

  @override
  String toString() =>
      'UserModel(id: $id, name: $name, phoneNumber: $phoneNumber, username: $username)';
}
