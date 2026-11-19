# frozen_string_literal: true

# #905: the one list of words that would name an SUD referral path, shared by
# the static scan (test/services/lakeraven/ehr/referral_surfaces_test.rb) and
# the rendered-page check (test/integration/referral_surfaces_rendered_test.rb).
module SudWords
  # Matched against the text as written and against the text with CamelCase
  # and snake_case opened into words (SudReferral, sud_program). The acronyms
  # match as whole words, or run together with what they would be offered as
  # (sudreferral, matprogram), so "sudo", "audit", "material" and "format"
  # never hit.
  SUD_WORDS = /
    substance | addict | opioid | opiate | alcohol | detox | methadone | buprenorphine | naloxone | naltrexone |
    suboxone | vivitrol | heroin | fentanyl | narcotic | drug | rehab | recovery | sober | sobriety | intoxication |
    SBIRT | MOUD | \bASAM\b |
    use[\s_-]*disorder | withdrawal[\s_-]*management | chemical[\s_-]*dependen |
    \b(?:SUD|OUD|AUD|MAT|AOD)(?=s?\b|[\s_-]*(?:referral|program|treatment|intake))
  /ix

  module_function

  # Text opened into words: CamelCase and snake_case boundaries become spaces.
  def words(text)
    text.to_s.gsub(/([a-z\d])([A-Z])/, '\1 \2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2').tr("_", " ")
  end

  # The SUD words in a text, as written or once opened into words.
  def hits(text)
    (text.to_s.scan(SUD_WORDS) + words(text).scan(SUD_WORDS)).uniq
  end
end
