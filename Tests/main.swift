import Foundation

var failures = 0

func check(_ actual: AutoOffAction, _ expected: AutoOffAction, _ name: String) {
    if actual == expected {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name): got \(actual), expected \(expected)")
    }
}

// threshold 0 disables the feature entirely
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 5, onAC: false, threshold: 0),
      .none, "threshold 0 disables")

// suspend just below threshold, on battery
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 19, onAC: false, threshold: 20),
      .suspend, "suspend below threshold on battery")

// no suspend exactly at threshold (strict less-than)
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 20, onAC: false, threshold: 20),
      .none, "no suspend at exactly threshold")

// never suspend on AC
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 5, onAC: true, threshold: 20),
      .none, "no suspend on AC")

// never suspend when the user hasn't turned Awayke on
check(AutoOffPolicy.decide(intent: false, suspended: false, percent: 5, onAC: false, threshold: 20),
      .none, "no suspend when intent off")

// resume at threshold + hysteresis, on AC
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 25, onAC: true, threshold: 20),
      .resume, "resume at threshold+hysteresis on AC")

// no resume below hysteresis band
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 24, onAC: true, threshold: 20),
      .none, "no resume below hysteresis")

// resume requires AC even when charge is high
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 30, onAC: false, threshold: 20),
      .none, "no resume on battery")

if failures > 0 {
    print("\(failures) failing")
    exit(1)
} else {
    print("all passing")
    exit(0)
}
