import 'package:comstar_bridge/geocode/nominatim_client.dart';
import 'package:comstar_bridge/presence_location.dart';
import 'package:test/test.dart';

void main() {
  group('PresenceLocationSpeech.tier', () {
    test('home', () {
      expect(
        PresenceLocationSpeech.tier(
          haState: 'home',
          inZones: const ['zone.home'],
        ),
        LocationSpeechTier.home,
      );
    });

    test('other country', () {
      expect(
        PresenceLocationSpeech.tier(
          haState: 'not_home',
          inZones: const [],
          home: const GeoPlace(countryCode: 'us', state: 'New York'),
          person: const GeoPlace(
            city: 'Melbourne',
            country: 'Australia',
            countryCode: 'au',
            state: 'Victoria',
          ),
          distanceKm: 16000,
        ),
        LocationSpeechTier.otherCountry,
      );
    });

    test('other state', () {
      expect(
        PresenceLocationSpeech.tier(
          haState: 'not_home',
          inZones: const [],
          home: const GeoPlace(countryCode: 'us', state: 'New York'),
          person: const GeoPlace(
            city: 'Atlanta',
            countryCode: 'us',
            state: 'Georgia',
          ),
          distanceKm: 1200,
        ),
        LocationSpeechTier.otherState,
      );
    });

    test('local nearby', () {
      expect(
        PresenceLocationSpeech.tier(
          haState: 'not_home',
          inZones: const [],
          home: const GeoPlace(countryCode: 'us', state: 'New York'),
          person: const GeoPlace(
            name: "Trader Joe's",
            road: 'Central Avenue',
            municipality: 'Town of Greenburgh',
            countryCode: 'us',
            state: 'New York',
          ),
          distanceKm: 4,
        ),
        LocationSpeechTier.local,
      );
    });

    test('same state farther', () {
      expect(
        PresenceLocationSpeech.tier(
          haState: 'not_home',
          inZones: const [],
          home: const GeoPlace(countryCode: 'us', state: 'New York'),
          person: const GeoPlace(
            city: 'New York',
            countryCode: 'us',
            state: 'New York',
          ),
          distanceKm: 35,
        ),
        LocationSpeechTier.sameState,
      );
    });
  });

  group('PresenceLocationSpeech.speakWhere', () {
    test('melbourne abroad', () {
      expect(
        PresenceLocationSpeech.speakWhere(
          displayName: 'Adna Zujo Lakisic',
          tier: LocationSpeechTier.otherCountry,
          person: const GeoPlace(
            city: 'Melbourne',
            country: 'Australia',
          ),
        ),
        'Adna Zujo Lakisic is in Melbourne, Australia.',
      );
    });

    test('atlanta other state', () {
      expect(
        PresenceLocationSpeech.speakWhere(
          displayName: 'Adna',
          tier: LocationSpeechTier.otherState,
          person: const GeoPlace(city: 'Atlanta', state: 'Georgia'),
        ),
        'Adna went to Atlanta, Georgia.',
      );
    });

    test('nyc same state', () {
      expect(
        PresenceLocationSpeech.speakWhere(
          displayName: 'Adna',
          tier: LocationSpeechTier.sameState,
          person: const GeoPlace(city: 'New York'),
        ),
        'Adna went to New York.',
      );
    });

    test('local trader joes', () {
      expect(
        PresenceLocationSpeech.speakWhere(
          displayName: 'Adna',
          tier: LocationSpeechTier.local,
          person: const GeoPlace(
            name: "Trader Joe's",
            road: 'Central Avenue',
            municipality: 'Town of Greenburgh',
          ),
        ),
        "Adna is at the Trader Joe's on Central Avenue in Greenburgh.",
      );
    });
  });

  group('PresenceLocationSpeech.lastLeftHomeAt', () {
    test('finds last home to away', () {
      final left = PresenceLocationSpeech.lastLeftHomeAt([
        {
          'state': 'home',
          'last_changed': '2026-08-01T10:00:00+00:00',
        },
        {
          'state': 'not_home',
          'last_changed': '2026-08-01T14:30:00+00:00',
        },
        {
          'state': 'home',
          'last_changed': '2026-08-02T09:00:00+00:00',
        },
        {
          'state': 'not_home',
          'last_changed': '2026-08-02T18:15:00+00:00',
        },
      ]);
      expect(left?.toUtc().toIso8601String(), '2026-08-02T18:15:00.000Z');
    });

    test('speakLeft when home', () {
      expect(
        PresenceLocationSpeech.speakLeft(
          displayName: 'Zlatko',
          haState: 'home',
          leftAt: DateTime.parse('2026-08-01T14:30:00Z'),
        ),
        'Zlatko is home — they have not left.',
      );
    });
  });

  group('haversineKm', () {
    test('home to melbourne is far', () {
      final km = haversineKm(41.01356, -73.80845, -37.8224, 144.9529);
      expect(km, greaterThan(15000));
    });
  });
}
