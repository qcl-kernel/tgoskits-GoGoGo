.PHONY: doctor model test images demo fault-test report

doctor:
	./scripts/doctor.sh

model:
	./scripts/build_model.sh

test:
	$(MAKE) -C tests test

images:
	./scripts/build_linux.sh
	./scripts/build_rtthread.sh
	./scripts/build_rtthread.sh --fault-drop-status-once

demo:
	./scripts/run_demo.sh

fault-test:
	./scripts/run_faults.sh

report:
	./scripts/render_report.py --latest
