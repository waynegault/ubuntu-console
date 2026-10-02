#!/usr/bin/env python3
"""
Salus Delayed Command Scheduler

Manages scheduled Salus commands for future execution. Supports:
- Schedule a command to run at a specific time in the future
- Persist scheduled tasks to JSON for durability across restarts
- Auto-cleanup of completed/expired tasks
- Asyncio-based execution with proper error handling
"""

import asyncio
import json
import logging
from dataclasses import dataclass, asdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List
import sys

logger = logging.getLogger(__name__)

# State file for persisting scheduled tasks
SCHEDULER_STATE_FILE = Path(__file__).parent / ".scheduler-state.json"


@dataclass
class ScheduledTask:
    """Represents a scheduled Salus command."""
    task_id: str
    scheduled_time: str  # ISO format
    command: List[str]  # CLI command as list: ["adjust-temp", "2"]
    description: str
    created_at: str  # ISO format
    status: str = "pending"  # pending, running, completed, failed, cancelled
    result: Optional[str] = None
    error: Optional[str] = None
    executed_at: Optional[str] = None

    def to_dict(self) -> Dict:
        """Convert to dictionary for JSON serialization."""
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Dict) -> "ScheduledTask":
        """Create from dictionary."""
        return cls(**data)


class SalusScheduler:
    """Manages scheduled execution of Salus CLI commands."""

    def __init__(self, state_file: Path = SCHEDULER_STATE_FILE):
        self.state_file = state_file
        self.tasks: Dict[str, ScheduledTask] = {}
        self.running_tasks: set = set()
        self._load_state()

    def _load_state(self) -> None:
        """Load persisted scheduled tasks from JSON file."""
        if self.state_file.exists():
            try:
                with open(self.state_file, "r") as f:
                    data = json.load(f)
                    for task_data in data.get("tasks", []):
                        task = ScheduledTask.from_dict(task_data)
                        self.tasks[task.task_id] = task
                logger.info(f"Loaded {len(self.tasks)} scheduled tasks from {self.state_file}")
            except Exception as e:
                logger.error(f"Failed to load scheduler state: {e}")

    def _save_state(self) -> None:
        """Persist scheduled tasks to JSON file."""
        try:
            with open(self.state_file, "w") as f:
                data = {
                    "saved_at": datetime.now().isoformat(),
                    "tasks": [task.to_dict() for task in self.tasks.values()]
                }
                json.dump(data, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save scheduler state: {e}")

    def schedule_command(
        self,
        command: List[str],
        delay_seconds: int,
        description: str = ""
    ) -> str:
        """
        Schedule a Salus CLI command to run after a delay.

        Args:
            command: CLI command as list, e.g., ["adjust-temp", "2"]
            delay_seconds: Delay in seconds before execution
            description: Human-readable description of what this command does

        Returns:
            task_id: Unique identifier for the scheduled task
        """
        import uuid
        task_id = str(uuid.uuid4())[:8]
        now = datetime.now()
        scheduled_time = now + timedelta(seconds=delay_seconds)

        task = ScheduledTask(
            task_id=task_id,
            scheduled_time=scheduled_time.isoformat(),
            command=command,
            description=description,
            created_at=now.isoformat(),
        )

        self.tasks[task_id] = task
        self._save_state()

        logger.info(
            f"Scheduled task {task_id}: {' '.join(command)} "
            f"in {delay_seconds}s at {scheduled_time.isoformat()}"
        )

        return task_id

    async def _execute_task(self, task: ScheduledTask) -> None:
        """
        Execute a single scheduled task.

        Args:
            task: The task to execute
        """
        self.running_tasks.add(task.task_id)
        task.status = "running"
        task.executed_at = datetime.now().isoformat()

        try:
            # Build the full command: python3 salus.py <command args>
            salus_script = Path(__file__).parent / "salus.py"
            full_command = [str(salus_script)] + task.command

            # Run the command
            result = await asyncio.create_subprocess_exec(
                sys.executable,
                *full_command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )

            stdout, stderr = await result.communicate()

            if result.returncode == 0:
                task.status = "completed"
                task.result = stdout.decode().strip()
                logger.info(f"Task {task.task_id} completed: {task.command}")
            else:
                task.status = "failed"
                task.error = stderr.decode().strip()
                logger.error(f"Task {task.task_id} failed: {task.error}")

        except Exception as e:
            task.status = "failed"
            task.error = str(e)
            logger.error(f"Task {task.task_id} exception: {e}")

        finally:
            self.running_tasks.discard(task.task_id)
            self._save_state()

    async def wait_and_execute(self, task_id: str) -> bool:
        """
        Wait for a task's scheduled time, then execute it.

        Args:
            task_id: The task to execute

        Returns:
            True if execution completed (regardless of success), False if task not found
        """
        if task_id not in self.tasks:
            logger.error(f"Task {task_id} not found")
            return False

        task = self.tasks[task_id]
        scheduled_time = datetime.fromisoformat(task.scheduled_time)
        now = datetime.now()
        delay = (scheduled_time - now).total_seconds()

        if delay > 0:
            logger.info(f"Task {task_id} will execute in {delay:.1f} seconds")
            await asyncio.sleep(delay)

        await self._execute_task(task)
        return True

    def get_task(self, task_id: str) -> Optional[ScheduledTask]:
        """Get a scheduled task by ID."""
        return self.tasks.get(task_id)

    def list_tasks(self, filter_status: Optional[str] = None) -> List[ScheduledTask]:
        """
        List all scheduled tasks.

        Args:
            filter_status: If provided, only return tasks with this status

        Returns:
            List of tasks, optionally filtered by status
        """
        tasks = list(self.tasks.values())
        if filter_status:
            tasks = [t for t in tasks if t.status == filter_status]
        return sorted(tasks, key=lambda t: t.scheduled_time)

    def cancel_task(self, task_id: str) -> bool:
        """
        Cancel a pending task.

        Args:
            task_id: The task to cancel

        Returns:
            True if cancelled, False if not found or not pending
        """
        if task_id not in self.tasks:
            return False

        task = self.tasks[task_id]
        if task.status != "pending":
            logger.warning(f"Cannot cancel task {task_id}: status is {task.status}")
            return False

        task.status = "cancelled"
        self._save_state()
        logger.info(f"Task {task_id} cancelled")
        return True

    def cleanup_old_tasks(self, older_than_days: int = 7) -> int:
        """
        Remove completed/failed tasks older than specified days.

        Args:
            older_than_days: Tasks created more than this many days ago are removed

        Returns:
            Number of tasks removed
        """
        cutoff = datetime.now() - timedelta(days=older_than_days)
        cutoff_iso = cutoff.isoformat()

        to_remove = [
            task_id
            for task_id, task in self.tasks.items()
            if task.status in ("completed", "failed", "cancelled")
            and task.created_at < cutoff_iso
        ]

        for task_id in to_remove:
            del self.tasks[task_id]

        if to_remove:
            self._save_state()
            logger.info(f"Cleaned up {len(to_remove)} old tasks")

        return len(to_remove)


# Singleton instance
_scheduler_instance: Optional[SalusScheduler] = None


def get_scheduler() -> SalusScheduler:
    """Get or create the global scheduler instance."""
    global _scheduler_instance
    if _scheduler_instance is None:
        _scheduler_instance = SalusScheduler()
    return _scheduler_instance


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    )

    # Example usage
    scheduler = get_scheduler()

    # Schedule a command
    task_id = scheduler.schedule_command(
        ["adjust-temp", "2"],
        delay_seconds=5,
        description="Increase temperature by 2 degrees"
    )

    print(f"Scheduled task: {task_id}")
    print(f"Pending tasks: {[t.task_id for t in scheduler.list_tasks('pending')]}")
