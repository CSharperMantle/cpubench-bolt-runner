CPUBench runner for BOLT
========================

This repository contains helper scripts to evaluate llvm-bolt[0] on the
CPUBench[1] benchmark suite.  It is expected to run on v1.3.2[2], but
should work with other versions as well.

The entrypoint script "cpubench-bolt.sh" runs a benchmark-profile-
optimize-benchmark workflow.  Adapt "source-bolt-flags.sh" to supply custom
flags to BOLT.


Licensing
---------

Copyright (c) 2026 Rong Bao <rong.bao@csmantle.top>

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
more details.

You should have received a copy of the GNU General Public License along with
this program.  If not, see <https://www.gnu.org/licenses/>.


---

[0]: https://github.com/llvm/llvm-project/tree/main/bolt
[1]: https://gitcode.com/benchmark-sig/cpubench
[2]: https://gitcode.com/benchmark-sig/cpubench/releases/v1.3.2
