defmodule ExPixBRCode do
  @moduledoc """
  Library for validating a BRCode string related to a Pix transfer.

  Pix is the new (2020) payment system in operation in Brasil from the central bank. One of its
  aspects is a specification for QRCodes and payment strings known as BR Code.

  One of the possible ways to initiate a payment is to read a QRCode or copy its content into your
  bank application. Then your application/service will validate it according to the specification
  and should provide the payment details.

  There are two types of BR Codes: static and dynamic. For static codes, everything needed to 
  present the payment details is already provided within the BR Code content. For dynamic codes
  you need to fetch the contents from a Pix endpoint.

  The process of validating Pix dynamic content is more complex. It has several steps that are 
  presented in the manual provided by the central bank. This library is an open-source way in an 
  attempt to become a standard implementation that can be used by financial institutions to 
  validate BR Codes.
  """
end
