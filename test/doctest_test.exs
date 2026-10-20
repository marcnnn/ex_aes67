defmodule ExAes67.DoctestTest do
  use ExUnit.Case, async: true

  for m <- [
        ExAes67.RTP,
        ExAes67.RTL.Slots,
        ExAes67.RTP.Payload,
        ExAes67.RTCP,
        ExAes67.SDP,
        ExAes67.SDP.Stream,
        ExAes67.SAP,
        ExAes67.DNS,
        ExAes67.RTSP,
        ExAes67.LinkBudget,
        ExAes67.Model.JitterBuffer,
        ExAes67.Model.SampleRing,
        ExAes67.Model.Depacketiser,
        ExAes67.Model.Packetiser
      ] do
    doctest m
  end
end
