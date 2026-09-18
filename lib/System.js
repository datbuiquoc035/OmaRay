// The System category: stock system.* rows verbatim — same order,
// same actions, same guards. Suspend/Hibernate run systemctl
// directly, exactly as the stock menu does.

function defs() {
  return [
    { key: "system.screensaver", title: "Screensaver", icon: "󱄄", action: 'omarchy-launch-screensaver force',
      confirm: false, when: '' },
    { key: "system.lock", title: "Lock", icon: "", action: 'omarchy-system-lock',
      confirm: false, when: '' },
    { key: "system.suspend", title: "Suspend", icon: "󰒲", action: 'systemctl suspend',
      confirm: true, when: '! omarchy-toggle-enabled suspend-off' },
    { key: "system.hibernate", title: "Hibernate", icon: "󰤁", action: 'systemctl hibernate',
      confirm: true, when: 'omarchy-hibernation-available' },
    { key: "system.logout", title: "Logout", icon: "󰍃", action: 'omarchy-system-logout',
      confirm: true, when: '' },
    { key: "system.reboot", title: "Reboot", icon: "󰜉", action: 'omarchy-system-reboot',
      confirm: true, when: '' },
    { key: "system.shutdown", title: "Shutdown", icon: "󰐥", action: 'omarchy-system-shutdown',
      confirm: true, when: '' },
  ]
}

if (typeof module !== "undefined") {
  module.exports = { defs: defs }
}
