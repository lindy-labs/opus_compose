pub mod addresses;
pub mod interfaces {
    pub mod erc20;
}
pub mod lever {
    pub mod constants;
    pub mod contracts {
        pub mod lever;
    }
    pub mod interfaces {
        pub mod lever;
    }
    pub mod types;

    #[cfg(test)]
    pub mod tests {
        pub mod malicious_lever;
        pub mod test_lever;
    }
}
pub mod stabilizer {
    pub mod constants;
    pub mod contracts {
        pub mod stabilizer;
    }
    pub mod interfaces {
        pub mod stabilizer;
    }
    pub mod math;
    pub mod periphery {
        pub mod estimator;
        pub mod frontend_data_provider;
    }
    pub mod types;

    #[cfg(test)]
    pub mod tests {
        mod test_estimator;
        mod test_stabilizer;
        pub mod utils;
    }
}

