import type { HarmonyDeskNative } from '../native/HarmonyDeskNative';

// ArkUI reports wheel motion in vp. Keep fractional movement between events;
// RustDesk's legacy wheel transport takes integral scroll steps (positive up).
export class WheelAccumulator {
  private remainder: number = 0;

  move(axis: number): number {
    if (!Number.isFinite(axis)) { return 0; }
    this.remainder -= axis / 15;
    const steps = Math.trunc(this.remainder);
    this.remainder -= steps;
    return steps === 0 ? 0 : steps;
  }

  reset(): void { this.remainder = 0; }
}

export class HardwarePointer {
  private held: Set<number> = new Set<number>();
  private wheel: WheelAccumulator = new WheelAccumulator();

  private native: HarmonyDeskNative;

  constructor(native: HarmonyDeskNative) { this.native = native; }

  move(x: number, y: number): void {
    this.native.sendMouseMove(x, y);
  }

  button(button: number, down: boolean): void {
    if (button < 0 || button > 2 || this.held.has(button) === down) { return; }
    if (down) { this.held.add(button); } else { this.held.delete(button); }
    this.native.sendMouseClick(button, down);
  }

  scroll(axis: number): void {
    const delta = this.wheel.move(axis);
    if (delta !== 0) { this.native.sendMouseWheel(delta); }
  }

  releaseAll(): void {
    this.held.forEach((button: number) => this.native.sendMouseClick(button, false));
    this.held.clear();
    this.wheel.reset();
  }
}
