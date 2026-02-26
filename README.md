## Appliance Checklist App

An iOS app for planning appliance delivery, installation, and pickup jobs with smart timing, checklists, and calendar + notification integration.

---

## Requirements

- **Xcode 15+** (iOS 17+ SDK)
- **iOS 17.0+** deployment target
- **Swift 5.9**

---

## Getting Started

### 1. Open the project
- Open `ApplianceChecklist.xcodeproj` in Xcode.

### 2. Configure signing
- In the **ApplianceChecklist** target, go to **Signing & Capabilities**.
- Select your **Development Team**.

### 3. Build & run
- Choose an iOS 17+ simulator or a physical device.
- Press **⌘R** to run.

> **If Xcode complains about the project:**  
> You can create a new iOS App project (SwiftUI + SwiftData) and drag everything from the `ApplianceChecklist/` folder into it, then copy the privacy keys from this `Info.plist`.

---

## Core Features

### Job Management
- **Job types**: Delivery, Installation, Pickup.
- **Simple form** to set:
  - Job title
  - Customer address (or “address not given yet”)
  - Appointment time
  - Number of people on the job
  - Optional installation add‑on
  - “Post‑tinkering” flag for extra testing reminders

### Smart Timing (Drive Time + Schedule Math)
- **Drive time minutes** stored per job.
- **Apple Maps–powered drive time**:
  - Set your **home address** once.
  - Type the job address and the app fetches drive time using MapKit Directions.
  - Drive time is displayed in **hours + minutes** (e.g. `45m`, `1h`, `1h 30m`).
- **Automatic schedule math per job type**:
  - Departure time (when to leave home).
  - Prep start time (when to start packing/loading).
  - Estimated return time.
  - Total job duration.

Underlying formulas:

| **Job Type** | **Total Duration** | **Prep Time (before departure)** |
|--------------|--------------------|----------------------------------|
| **Delivery** | \((2 × DriveTime) + (30 ÷ people) + 30 min if installation add‑on\) | 60 min |
| **Installation** | \((2 × DriveTime) + 30 min\) | 30 min |
| **Pickup** | \((2 × DriveTime) + (30 ÷ people)\) | 45 min |

### Calendar Sync (EventKit)
- Automatically creates/updates a **calendar event** per job:
  - Blocks out the entire job duration on your calendar.
  - Uses the calculated start/end times.
- Keeps the event in sync when you edit a job.

### Notifications
- **Prep reminder** before you leave:
  - Delivery: 60 minutes before departure
  - Pickup: 45 minutes before departure
  - Installation: 30 minutes before departure
- **Departure alert** when it’s time to leave.
- **Post‑tinkering reminder** at the end of the job: “ALWAYS test after you fix/change something”.

### Checklists
Pre‑built checklists tailored to each job type:

- **Delivery**: Ramp, Dolly, Two Heavy Duty Straps, Couple of Rags, Runners, Washer Hot and Cold Connections, Washer Drain Pipe, Dryer plug INSTALLED, The opposite dryer cord, Check Gas.
- **Installation**: Screwdriver, Impact with drills bit, Channel Lock Pliers.
- **Pickup**: Dolly, Two Heavy Duty Straps, Dolly Strap, Ramp, Runner/Rags, Cash, Check Gas.
- **Post‑Tinkering**: “ALWAYS test after you fix/change something”.

Each job tracks which items are checked off and shows progress.

### Drive Time UX (V4 Enhancements)
- **Map‑powered address autocomplete**:
  - Job address and home address fields both use MapKit search suggestions.
  - As you type, a dropdown shows up to **5** of the most relevant addresses/places.
  - Tapping a suggestion fills the field and hides the dropdown.
- **Drive time editing rules**:
  - If **address is not given yet**, drive time is **fully editable** with a stepper.
  - Once an address is set, drive time becomes **read‑only** and is driven by the Maps estimate, with a small “Refresh” button to re‑fetch.

---

## Permissions & Privacy

The app requests:

- **Calendar Access** (`NSCalendarsFullAccessUsageDescription`)  
  To create and manage job events in your calendar.
- **Notification Permission**  
  To send prep and departure reminders and post‑tinkering alerts.

Location search and drive time use **Apple MapKit** (geocoding + directions). No third‑party location services are used, and search queries are only sent to Apple’s APIs via the standard MapKit SDK.
