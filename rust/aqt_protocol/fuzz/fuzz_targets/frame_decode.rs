// SPDX-License-Identifier: GPL-3.0-or-later
#![no_main]
use libfuzzer_sys::fuzz_target;
use aqt_protocol::frame::*;
use bytes::Buf;

fuzz_target!(|data: &[u8]| {
    let mut b: &[u8] = data;
    while b.remaining() > 0 {
        match decode_frame_header(&mut b) {
            Ok((op, len)) => {
                if b.remaining() < len { break; }
                let mut payload = &b[..len];
                let advance = len;
                match op {
                    Opcode::Hello        => { let _ = Hello::decode(&mut payload); }
                    Opcode::HelloAck     => { let _ = HelloAck::decode(&mut payload); }
                    Opcode::OpenTab      => { let _ = OpenTab::decode(&mut payload); }
                    Opcode::OpenTabAck   => { let _ = OpenTabAck::decode(&mut payload); }
                    Opcode::Resize       => { let _ = Resize::decode(&mut payload); }
                    Opcode::Signal       => { let _ = Signal::decode(&mut payload); }
                    Opcode::CloseTab     => { let _ = CloseTab::decode(&mut payload); }
                    Opcode::Resume       => { let _ = Resume::decode(&mut payload); }
                    Opcode::ResumeAck    => { let _ = ResumeAck::decode(&mut payload); }
                    Opcode::OpenFile     => { let _ = OpenFile::decode(&mut payload); }
                    Opcode::OpenFileAck  => { let _ = OpenFileAck::decode(&mut payload); }
                    Opcode::FileProgress => { let _ = FileProgress::decode(&mut payload); }
                    Opcode::FileDone     => { let _ = FileDone::decode(&mut payload); }
                    Opcode::ListHistory       => { let _ = ListHistory::decode(&mut payload); }
                    Opcode::ListHistoryResp   => { let _ = ListHistoryResp::decode(&mut payload); }
                    Opcode::HistoryPreloadDone => { let _ = HistoryPreloadDone::decode(&mut payload); }
                    Opcode::Notify            => { let _ = Notify::decode(&mut payload); }
                    Opcode::NotifyAck         => { let _ = NotifyAck::decode(&mut payload); }
                }
                b.advance(advance);
            }
            Err(_) => break,
        }
    }
});
