# JCOG iOS Memo App

This Flutter project provides a memo/reminder application with:

- Normal users do not need to log in.
- Admins can enter admin mode with a password and create memos for all users.
- Firebase Cloud Firestore is used to sync memos across phones.
- Firebase Cloud Messaging is used to receive push reminders.

## How it works

- Regular users just install and open the app.
- Admins tap the admin icon and enter the password `admin123`.
- Admin creates a memo and schedules the reminder time.
- All installed apps subscribe to the `memo_all` topic and can receive notifications.

## Firebase setup

This project requires Firebase configuration files:

- `GoogleService-Info.plist` for iOS
- `google-services.json` for Android (if you want Android support)

Also configure Firebase Cloud Messaging and a server/Cloud Function to send topic messages to `memo_all` when a memo is created.

## Run

From the `JCOG_ios` folder:

```powershell
C:\Users\103-7351\flutter\bin\flutter.bat pub get
C:\Users\103-7351\flutter\bin\flutter.bat run
```

## Notes

- On Windows you still need Developer Mode enabled for plugin symlink support.
- For native Windows builds, install Visual Studio with "Desktop development with C++".
