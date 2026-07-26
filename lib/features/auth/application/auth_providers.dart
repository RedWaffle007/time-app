import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../data/profile_repository.dart';
import '../domain/user_profile.dart';

// --- Repositories (plain providers, created once) ---

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(FirebaseAuth.instance);
});

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(FirebaseFirestore.instance);
});

// --- Reactive state ---

/// Emits the signed-in Firebase user, or null when signed out.
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges();
});

/// The signed-in user's uid, or null. A one-line projection of
/// [authStateProvider] that exists so everything downstream depends on a plain
/// `String?` instead of a `firebase_auth` `User` — which makes those providers
/// testable by overriding this, with no Firebase in the test at all.
final currentUidProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).value?.uid;
});

/// Emits the current user's profile:
///   - null when signed out, OR signed in but no profile doc yet
///   - a UserProfile once the profile exists
///
/// It rebuilds automatically when auth state changes because it watches
/// authStateProvider.
final profileProvider = StreamProvider<UserProfile?>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) {
    return Stream.value(null);
  }
  return ref.watch(profileRepositoryProvider).watchProfile(user.uid);
});

/// Any user's profile by uid — used to read a planning target's name + home
/// timezone. Family is warranted (it's parameterised by uid).
final profileByUidProvider =
    StreamProvider.family<UserProfile?, String>((ref, uid) {
  return ref.watch(profileRepositoryProvider).watchProfile(uid);
});
