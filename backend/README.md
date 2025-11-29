# Locus Backend

This is the backend server for the Locus tracking app. It provides the API for the mobile app and serves the web dashboard.

## Prerequisites

- Node.js (v14 or higher)
- NPM (Node Package Manager)

## Setup

1.  Navigate to the `backend` directory:
    ```bash
    cd backend
    ```

2.  Install dependencies:
    ```bash
    npm install
    ```

## Running the Server

Start the server:
```bash
npm start
```

The server will run on `http://localhost:3000` (or the port specified in `PORT` environment variable).

## Dashboard

Access the dashboard by opening `http://localhost:3000` in your web browser.

## Mobile App Configuration

In the Locus mobile app, go to Settings and set the API Base URL to your server's address.
- If running on an emulator/simulator on the same machine, use `http://10.0.2.2:3000` (Android) or `http://localhost:3000` (iOS).
- If running on a physical device, ensure both device and server are on the same Wi-Fi network, and use your computer's local IP address (e.g., `http://192.168.1.100:3000`).
