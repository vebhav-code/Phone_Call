class UserModel {
  final String id;
  final String name;
  final String username;

  const UserModel({
    required this.id,
    required this.name,
    required this.username,
  });

  /// Factory constructor to parse JSON response from the backend
  /// matching POST /users, GET /users/search, and GET /users/{id}.
  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      username: (json['username'] ?? '').toString(),
    );
  }

  /// Converts the UserModel into a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'username': username,
    };
  }

  UserModel copyWith({
    String? id,
    String? name,
    String? username,
  }) {
    return UserModel(
      id: id ?? this.id,
      name: name ?? this.name,
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
          username == other.username;

  @override
  int get hashCode => id.hashCode ^ name.hashCode ^ username.hashCode;

  @override
  String toString() => 'UserModel(id: $id, name: $name, username: $username)';
}
